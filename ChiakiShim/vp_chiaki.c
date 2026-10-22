// vp_chiaki.c — chiaki-ng backed implementation of vp_chiaki.h.
//
// SPDX-License-Identifier: AGPL-3.0-only (links chiaki-ng)
//
// Compiled INSIDE chiaki-lib (see Tools/build_libchiaki_visionos.sh) so that
// ChiakiSession and friends use the library's exact struct layout. Never move
// this file into the Xcode target.

#include "vp_chiaki.h"

#include <chiaki/common.h>
#include <chiaki/controller.h>
#include <chiaki/discovery.h>
#include <chiaki/discoveryservice.h>
#include <chiaki/log.h>
#include <chiaki/opusdecoder.h>
#include <chiaki/orientation.h>
#include <chiaki/time.h>
#include <chiaki/regist.h>
#include <chiaki/session.h>

#include <signal.h>
#include <stdlib.h>
#include <string.h>

#include <netinet/in.h>
#include <sys/socket.h>

// MARK: - Logging

typedef struct {
    VPLogCallback cb;
    void *user;
} VPLogSink;

static void vp_log_trampoline(ChiakiLogLevel level, const char *msg, void *user)
{
    VPLogSink *sink = user;
    if(sink && sink->cb)
        sink->cb((int)level, msg, sink->user);
}

static void vp_log_setup(ChiakiLog *log, VPLogSink *sink, VPLogCallback cb, void *user)
{
    sink->cb = cb;
    sink->user = user;
    uint32_t mask = CHIAKI_LOG_ERROR | CHIAKI_LOG_WARNING | CHIAKI_LOG_INFO;
    chiaki_log_init(log, mask, cb ? vp_log_trampoline : NULL, sink);
}

int vp_lib_init(void)
{
    // chiaki writes to TCP sockets the console may already have closed (e.g. a
    // rejected pairing). Without this, send() raises SIGPIPE and kills the app.
    signal(SIGPIPE, SIG_IGN);
    return (int)chiaki_lib_init();
}

const char *vp_error_string(int error)
{
    return chiaki_error_string((ChiakiErrorCode)error);
}

// MARK: - Session

struct VPSession {
    ChiakiSession session;
    ChiakiLog log;
    VPLogSink log_sink;
    ChiakiOpusDecoder opus;
    VPSessionConfig config;   // callbacks + user; `host` points at host_copy
    char *host_copy;
    bool started;
    bool joined;
    // Touch ids and the orientation integrator live here so the app only
    // reports raw finger positions and sensor values.
    ChiakiControllerState touch_state;
    int8_t touch_ids[2];
    ChiakiOrientationTracker orient;
    ChiakiAccelNewZero accel_zero;
};

static void vp_session_event_cb(ChiakiEvent *event, void *user)
{
    VPSession *s = user;
    if(!s->config.event_cb)
        return;

    VPEvent out;
    memset(&out, 0, sizeof(out));
    switch(event->type)
    {
        case CHIAKI_EVENT_CONNECTED:
            out.type = VP_EVENT_CONNECTED;
            break;
        case CHIAKI_EVENT_QUIT:
            out.type = VP_EVENT_QUIT;
            out.quit_reason = (int)event->quit.reason;
            out.quit_is_error = chiaki_quit_reason_is_error(event->quit.reason);
            out.quit_text = event->quit.reason_str
                ? event->quit.reason_str
                : chiaki_quit_reason_string(event->quit.reason);
            break;
        case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
            out.type = VP_EVENT_LOGIN_PIN_REQUEST;
            out.pin_incorrect = event->login_pin_request.pin_incorrect;
            break;
        case CHIAKI_EVENT_RUMBLE:
            out.type = VP_EVENT_RUMBLE;
            out.rumble_left = event->rumble.left;
            out.rumble_right = event->rumble.right;
            break;
        case CHIAKI_EVENT_NICKNAME_RECEIVED:
            out.type = VP_EVENT_NICKNAME;
            out.nickname = event->server_nickname;
            break;
        case CHIAKI_EVENT_TRIGGER_EFFECTS:
            out.type = VP_EVENT_TRIGGER_EFFECTS;
            out.trigger_type_left = event->trigger_effects.type_left;
            out.trigger_type_right = event->trigger_effects.type_right;
            memcpy(out.trigger_left, event->trigger_effects.left, sizeof(out.trigger_left));
            memcpy(out.trigger_right, event->trigger_effects.right, sizeof(out.trigger_right));
            break;
        case CHIAKI_EVENT_LED_COLOR:
            out.type = VP_EVENT_LED_COLOR;
            memcpy(out.led_rgb, event->led_state, sizeof(out.led_rgb));
            break;
        case CHIAKI_EVENT_MOTION_RESET:
            out.type = VP_EVENT_MOTION_RESET;
            chiaki_orientation_tracker_init(&s->orient);
            break;
        default:
            return; // not exposed yet (keyboard, haptics, LED, ...)
    }
    s->config.event_cb(&out, s->config.user);
}

static bool vp_session_video_cb(uint8_t *buf, size_t buf_size, int32_t frames_lost,
                                bool frame_recovered, void *user)
{
    VPSession *s = user;
    if(!s->config.video_cb)
        return true;
    return s->config.video_cb(buf, buf_size, frames_lost, frame_recovered, s->config.user);
}

static void vp_opus_settings_cb(uint32_t channels, uint32_t rate, void *user)
{
    VPSession *s = user;
    if(s->config.audio_format_cb)
        s->config.audio_format_cb(channels, rate, s->config.user);
}

static void vp_opus_frame_cb(int16_t *buf, size_t samples_count, void *user)
{
    VPSession *s = user;
    if(s->config.audio_frame_cb)
        s->config.audio_frame_cb(buf, samples_count, s->config.user);
}

static void vp_haptics_frame_cb(uint8_t *buf, size_t buf_size, void *user)
{
    VPSession *s = user;
    if(!s->config.haptics_cb || !buf)
        return;
    size_t frames = buf_size / (2 * sizeof(int16_t));
    if(frames == 0)
        return;
    int16_t pcm[256 * 2];
    if(frames > 256)
        frames = 256;
    memcpy(pcm, buf, frames * 2 * sizeof(int16_t));   // buf may be unaligned
    s->config.haptics_cb(pcm, frames, s->config.user);
}

static ChiakiVideoResolutionPreset vp_resolution_preset(int resolution)
{
    switch(resolution)
    {
        case 360: return CHIAKI_VIDEO_RESOLUTION_PRESET_360p;
        case 540: return CHIAKI_VIDEO_RESOLUTION_PRESET_540p;
        case 720: return CHIAKI_VIDEO_RESOLUTION_PRESET_720p;
        default:  return CHIAKI_VIDEO_RESOLUTION_PRESET_1080p;
    }
}

VPSession *vp_session_create(const VPSessionConfig *config, int *error_out)
{
    if(error_out)
        *error_out = CHIAKI_ERR_SUCCESS;
    if(!config || !config->host)
    {
        if(error_out) *error_out = CHIAKI_ERR_INVALID_DATA;
        return NULL;
    }

    VPSession *s = calloc(1, sizeof(VPSession));
    if(!s)
    {
        if(error_out) *error_out = CHIAKI_ERR_MEMORY;
        return NULL;
    }
    s->config = *config;
    s->host_copy = strdup(config->host);
    s->config.host = s->host_copy;
    vp_log_setup(&s->log, &s->log_sink, config->log_cb, config->user);

    ChiakiConnectInfo info;
    memset(&info, 0, sizeof(info));
    info.ps5 = config->ps5;
    info.host = s->host_copy;
    memcpy(info.regist_key, config->regist_key, sizeof(info.regist_key));
    memcpy(info.morning, config->morning, sizeof(info.morning));
    memcpy(info.psn_account_id, config->psn_account_id, sizeof(info.psn_account_id));

    chiaki_connect_video_profile_preset(&info.video_profile,
        vp_resolution_preset(config->resolution),
        config->fps >= 60 ? CHIAKI_VIDEO_FPS_PRESET_60 : CHIAKI_VIDEO_FPS_PRESET_30);
    if(config->bitrate_kbps > 0)
        info.video_profile.bitrate = config->bitrate_kbps;
    // PS4 only speaks H.264.
    info.video_profile.codec = config->ps5 ? (ChiakiCodec)config->codec : CHIAKI_CODEC_H264;
    info.video_profile_auto_downgrade = true;
    info.enable_keyboard = false;
    info.enable_dualsense = true;
    info.audio_video_disabled = CHIAKI_NONE_DISABLED;
    info.auto_regist = false;
    info.holepunch_session = NULL;
    info.rudp_sock = NULL;
    info.packet_loss_max = 0.05;

    ChiakiErrorCode err = chiaki_session_init(&s->session, &info, &s->log);
    if(err != CHIAKI_ERR_SUCCESS)
    {
        if(error_out) *error_out = err;
        free(s->host_copy);
        free(s);
        return NULL;
    }

    // Safe here: this file is compiled with the library's own flags.
    chiaki_session_set_event_cb(&s->session, vp_session_event_cb, s);
    chiaki_session_set_video_sample_cb(&s->session, vp_session_video_cb, s);

    chiaki_opus_decoder_init(&s->opus, &s->log);
    chiaki_opus_decoder_set_cb(&s->opus, vp_opus_settings_cb, vp_opus_frame_cb, s);
    ChiakiAudioSink sink;
    chiaki_opus_decoder_get_sink(&s->opus, &sink);
    chiaki_session_set_audio_sink(&s->session, &sink);

    if(config->haptics_cb)
    {
        ChiakiAudioSink haptics;
        memset(&haptics, 0, sizeof(haptics));
        haptics.user = s;
        haptics.frame_cb = vp_haptics_frame_cb;
        chiaki_session_set_haptics_sink(&s->session, &haptics);
    }

    chiaki_controller_state_set_idle(&s->touch_state);
    s->touch_ids[0] = s->touch_ids[1] = -1;
    chiaki_orientation_tracker_init(&s->orient);
    chiaki_accel_new_zero_set_inactive(&s->accel_zero, true);

    return s;
}

int vp_session_start(VPSession *s)
{
    if(!s || s->started)
        return CHIAKI_ERR_UNKNOWN;
    ChiakiErrorCode err = chiaki_session_start(&s->session);
    if(err == CHIAKI_ERR_SUCCESS)
        s->started = true;
    return err;
}

void vp_session_stop(VPSession *s)
{
    if(s && s->started)
        chiaki_session_stop(&s->session);
}

void vp_session_destroy(VPSession *s)
{
    if(!s)
        return;
    if(s->started && !s->joined)
    {
        chiaki_session_stop(&s->session);
        chiaki_session_join(&s->session);
        s->joined = true;
    }
    chiaki_session_fini(&s->session);
    chiaki_opus_decoder_fini(&s->opus);
    free(s->host_copy);
    free(s);
}

int vp_session_set_controller(VPSession *s, const VPControllerState *state)
{
    if(!s || !state)
        return CHIAKI_ERR_INVALID_DATA;
    ChiakiControllerState cs;
    chiaki_controller_state_set_idle(&cs);
    cs.buttons = state->buttons;
    cs.l2_state = state->l2;
    cs.r2_state = state->r2;
    cs.left_x = state->left_x;
    cs.left_y = state->left_y;
    cs.right_x = state->right_x;
    cs.right_y = state->right_y;

    // Touchpad: translate finger down/move/up into chiaki touch ids.
    for(int i = 0; i < 2; i++)
    {
        if(state->touch_down[i])
        {
            uint16_t x = state->touch_x[i] > 1919 ? 1919 : state->touch_x[i];
            uint16_t y = state->touch_y[i] > 941 ? 941 : state->touch_y[i];
            if(s->touch_ids[i] < 0)
                s->touch_ids[i] = chiaki_controller_state_start_touch(&s->touch_state, x, y);
            else
                chiaki_controller_state_set_touch_pos(&s->touch_state, (uint8_t)s->touch_ids[i], x, y);
        }
        else if(s->touch_ids[i] >= 0)
        {
            chiaki_controller_state_stop_touch(&s->touch_state, (uint8_t)s->touch_ids[i]);
            s->touch_ids[i] = -1;
        }
    }
    cs.touch_id_next = s->touch_state.touch_id_next;
    memcpy(cs.touches, s->touch_state.touches, sizeof(cs.touches));

    if(state->has_motion)
    {
        uint32_t ts = (uint32_t)(chiaki_time_now_monotonic_us() & 0xffffffff);
        chiaki_orientation_tracker_update(&s->orient,
            state->gyro[0], state->gyro[1], state->gyro[2],
            state->accel[0], state->accel[1], state->accel[2],
            &s->accel_zero, true, ts);
        chiaki_orientation_tracker_apply_to_controller_state(&s->orient, &cs);
    }
    return chiaki_session_set_controller_state(&s->session, &cs);
}

int vp_session_set_login_pin(VPSession *s, const char *pin)
{
    if(!s || !pin)
        return CHIAKI_ERR_INVALID_DATA;
    return chiaki_session_set_login_pin(&s->session, (const uint8_t *)pin, strlen(pin));
}

int vp_session_request_idr(VPSession *s)
{
    // The pinned Pylux version does not expose a manual IDR request API.
    return s ? CHIAKI_ERR_VERSION_MISMATCH : CHIAKI_ERR_INVALID_DATA;
}

int vp_session_go_home(VPSession *s)
{
    return s ? chiaki_session_go_home(&s->session) : CHIAKI_ERR_INVALID_DATA;
}

int vp_session_sleep_console(VPSession *s)
{
    return s ? chiaki_session_goto_bed(&s->session) : CHIAKI_ERR_INVALID_DATA;
}

int vp_session_get_stats(VPSession *s, VPStreamStats *out)
{
    if(!s || !out)
        return CHIAKI_ERR_INVALID_DATA;
    memset(out, 0, sizeof(*out));
    if(!s->started)
        return CHIAKI_ERR_SUCCESS;
    ChiakiStreamConnection *sc = &s->session.stream_connection;
    out->bitrate_mbps = sc->measured_bitrate;
    out->rtt_ms = (double)s->session.rtt_us / 1000.0;
    out->packet_loss = sc->congestion_control.packet_loss;
    return CHIAKI_ERR_SUCCESS;
}

// MARK: - Registration

struct VPRegist {
    ChiakiRegist regist;
    ChiakiLog log;
    VPLogSink log_sink;
    VPRegistCallback cb;
    void *user;
    char *host_copy;
};

static void vp_regist_cb(ChiakiRegistEvent *event, void *user)
{
    VPRegist *r = user;
    if(!r->cb)
        return;
    switch(event->type)
    {
        case CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS:
        {
            VPRegisteredHost host;
            memset(&host, 0, sizeof(host));
            ChiakiRegisteredHost *src = event->registered_host;
            host.ps5 = chiaki_target_is_ps5(src->target);
            strncpy(host.nickname, src->server_nickname, sizeof(host.nickname) - 1);
            memcpy(host.regist_key, src->rp_regist_key, VP_KEY_SIZE);
            memcpy(host.morning, src->rp_key, VP_KEY_SIZE);
            memcpy(host.mac, src->server_mac, sizeof(host.mac));
            r->cb(VP_REGIST_SUCCESS, &host, r->user);
            break;
        }
        case CHIAKI_REGIST_EVENT_TYPE_FINISHED_CANCELED:
            r->cb(VP_REGIST_CANCELED, NULL, r->user);
            break;
        default:
            r->cb(VP_REGIST_FAILED, NULL, r->user);
            break;
    }
}

VPRegist *vp_regist_start(const char *host, bool ps5, bool broadcast,
                          const uint8_t psn_account_id[VP_ACCOUNT_ID_SIZE], uint32_t pin,
                          VPRegistCallback cb, VPLogCallback log_cb, void *user, int *error_out)
{
    if(error_out)
        *error_out = CHIAKI_ERR_SUCCESS;
    VPRegist *r = calloc(1, sizeof(VPRegist));
    if(!r)
    {
        if(error_out) *error_out = CHIAKI_ERR_MEMORY;
        return NULL;
    }
    r->cb = cb;
    r->user = user;
    r->host_copy = strdup(host ? host : "255.255.255.255");
    vp_log_setup(&r->log, &r->log_sink, log_cb, user);

    ChiakiRegistInfo info;
    memset(&info, 0, sizeof(info));
    info.target = ps5 ? CHIAKI_TARGET_PS5_1 : CHIAKI_TARGET_PS4_10;
    info.host = r->host_copy;
    info.broadcast = broadcast;
    info.psn_online_id = NULL;
    memcpy(info.psn_account_id, psn_account_id, CHIAKI_PSN_ACCOUNT_ID_SIZE);
    info.pin = pin;
    info.console_pin = 0;
    info.holepunch_info = NULL;
    info.rudp = NULL;

    ChiakiErrorCode err = chiaki_regist_start(&r->regist, &r->log, &info, vp_regist_cb, r);
    if(err != CHIAKI_ERR_SUCCESS)
    {
        if(error_out) *error_out = err;
        free(r->host_copy);
        free(r);
        return NULL;
    }
    return r;
}

void vp_regist_destroy(VPRegist *r)
{
    if(!r)
        return;
    chiaki_regist_stop(&r->regist);
    chiaki_regist_fini(&r->regist);
    free(r->host_copy);
    free(r);
}

// MARK: - Wakeup

int vp_wakeup(const char *host, const uint8_t regist_key[VP_KEY_SIZE], bool ps5)
{
    // The credential is the ASCII hex regist key (up to the first NUL) parsed
    // as a number — same as chiaki-ng's DiscoveryManager.
    char key[VP_KEY_SIZE + 1];
    memcpy(key, regist_key, VP_KEY_SIZE);
    key[VP_KEY_SIZE] = '\0';
    size_t len = strlen(key);
    if(len == 0 || len > 8)
        return CHIAKI_ERR_INVALID_DATA;
    char *end = NULL;
    uint64_t credential = strtoull(key, &end, 16);
    if(!end || *end != '\0')
        return CHIAKI_ERR_INVALID_DATA;

    ChiakiLog log;
    chiaki_log_init(&log, CHIAKI_LOG_ERROR | CHIAKI_LOG_WARNING, NULL, NULL);
    return chiaki_discovery_wakeup(&log, NULL, host, credential, ps5);
}

// MARK: - Discovery

struct VPDiscovery {
    ChiakiDiscoveryService service;
    ChiakiLog log;
    VPLogSink log_sink;
    VPDiscoveryCallback cb;
    void *user;
    char *host_copy;
};

#define VP_DISCOVERY_MAX 16

static void vp_discovery_cb(ChiakiDiscoveryHost *hosts, size_t count, void *user)
{
    VPDiscovery *d = user;
    if(!d->cb)
        return;
    if(count > VP_DISCOVERY_MAX)
        count = VP_DISCOVERY_MAX;
    VPDiscoveredHost out[VP_DISCOVERY_MAX];
    for(size_t i = 0; i < count; i++)
    {
        ChiakiDiscoveryHost *h = &hosts[i];
        switch(h->state)
        {
            case CHIAKI_DISCOVERY_HOST_STATE_READY: out[i].state = VP_HOST_READY; break;
            case CHIAKI_DISCOVERY_HOST_STATE_STANDBY: out[i].state = VP_HOST_STANDBY; break;
            default: out[i].state = VP_HOST_UNKNOWN; break;
        }
        out[i].ps5 = chiaki_discovery_host_is_ps5(h);
        out[i].host_addr = h->host_addr;
        out[i].host_name = h->host_name;
        out[i].host_id = h->host_id;
        out[i].running_app_name = h->running_app_name;
    }
    d->cb(out, count, d->user);
}

VPDiscovery *vp_discovery_start(const char *unicast_host, VPDiscoveryCallback cb,
                                VPLogCallback log_cb, void *user)
{
    VPDiscovery *d = calloc(1, sizeof(VPDiscovery));
    if(!d)
        return NULL;
    d->cb = cb;
    d->user = user;
    vp_log_setup(&d->log, &d->log_sink, log_cb, user);

    ChiakiDiscoveryServiceOptions options;
    memset(&options, 0, sizeof(options));
    options.ping_ms = 500;
    options.ping_initial_ms = 100;
    options.host_drop_pings = 3;
    options.cb = vp_discovery_cb;
    options.cb_user = d;
    options.broadcast_addrs = NULL;
    options.broadcast_num = 0;

    struct sockaddr_storage addr;
    memset(&addr, 0, sizeof(addr));
    if(unicast_host)
    {
        d->host_copy = strdup(unicast_host);
        options.hosts_max = 1;
        options.send_host = d->host_copy;
        bool ipv6 = strchr(unicast_host, ':') != NULL;
        addr.ss_family = ipv6 ? AF_INET6 : AF_INET;
        options.send_addr_size = ipv6 ? sizeof(struct sockaddr_in6) : sizeof(struct sockaddr_in);
    }
    else
    {
        options.hosts_max = VP_DISCOVERY_MAX;
        options.send_host = NULL;
        struct sockaddr_in in_addr;
        memset(&in_addr, 0, sizeof(in_addr));
        in_addr.sin_family = AF_INET;
        in_addr.sin_addr.s_addr = 0xffffffff; // 255.255.255.255
        memcpy(&addr, &in_addr, sizeof(in_addr));
        options.send_addr_size = sizeof(in_addr);
    }
    options.send_addr = &addr; // copied by the service during init

    if(chiaki_discovery_service_init(&d->service, &options, &d->log) != CHIAKI_ERR_SUCCESS)
    {
        free(d->host_copy);
        free(d);
        return NULL;
    }
    return d;
}

void vp_discovery_destroy(VPDiscovery *d)
{
    if(!d)
        return;
    chiaki_discovery_service_fini(&d->service);
    free(d->host_copy);
    free(d);
}
