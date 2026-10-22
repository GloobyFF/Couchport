// vp_chiaki.h — the ONLY interface the app sees for PlayStation Remote Play.
//
// Phase 1: implemented by vp_chiaki.c on top of chiaki-ng (AGPL-3.0). The C
// file is compiled *inside* the chiaki static library by
// Tools/build_libchiaki_visionos.sh, so every ChiakiSession field offset
// matches the library's own build flags (mbedTLS etc.). App code never
// includes a chiaki header and never touches a chiaki struct.
//
// Phase 2 (clean-room): re-implement this same API in Swift/C without chiaki
// code, then drop the library. Keep this header free of chiaki types.

#ifndef VP_CHIAKI_H
#define VP_CHIAKI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Bumped whenever this header changes. Rebuild VPChiaki.xcframework with
/// Tools/build_libchiaki_visionos.sh after updating the app sources.
#define VP_CHIAKI_API_VERSION 2

#define VP_KEY_SIZE 16
#define VP_ACCOUNT_ID_SIZE 8

typedef struct VPSession VPSession;
typedef struct VPRegist VPRegist;
typedef struct VPDiscovery VPDiscovery;

// MARK: - Common

typedef enum {
    VP_LOG_ERROR = 1,
    VP_LOG_WARNING = 2,
    VP_LOG_INFO = 4,
    VP_LOG_VERBOSE = 8,
    VP_LOG_DEBUG = 16
} VPLogLevel;

typedef void (*VPLogCallback)(int level, const char *message, void *user);

/// Call once per process before anything else. Returns 0 on success.
int vp_lib_init(void);
const char *vp_error_string(int error);

// MARK: - Session

typedef enum {
    VP_EVENT_CONNECTED = 1,
    VP_EVENT_QUIT = 2,
    VP_EVENT_LOGIN_PIN_REQUEST = 3,
    VP_EVENT_RUMBLE = 4,
    VP_EVENT_NICKNAME = 5,
    VP_EVENT_TRIGGER_EFFECTS = 6,   // DualSense adaptive trigger effect (raw DS5 bytes)
    VP_EVENT_LED_COLOR = 7,         // light bar colour
    VP_EVENT_MOTION_RESET = 8       // console asks to re-zero motion
} VPEventType;

typedef struct {
    VPEventType type;
    int quit_reason;          // VP_EVENT_QUIT
    bool quit_is_error;       // VP_EVENT_QUIT
    const char *quit_text;    // VP_EVENT_QUIT, may be NULL; valid during callback only
    uint8_t rumble_left;      // VP_EVENT_RUMBLE (low frequency)
    uint8_t rumble_right;     // VP_EVENT_RUMBLE (high frequency)
    bool pin_incorrect;       // VP_EVENT_LOGIN_PIN_REQUEST
    const char *nickname;     // VP_EVENT_NICKNAME; valid during callback only
    uint8_t trigger_type_left;   // VP_EVENT_TRIGGER_EFFECTS: DS5 effect mode byte
    uint8_t trigger_type_right;
    uint8_t trigger_left[10];    // DS5 effect parameters
    uint8_t trigger_right[10];
    uint8_t led_rgb[3];          // VP_EVENT_LED_COLOR
} VPEvent;

typedef void (*VPEventCallback)(const VPEvent *event, void *user);
/// One Annex-B access unit (H.264 or HEVC). Return false if it could not be
/// decoded so the console sends a new keyframe.
typedef bool (*VPVideoCallback)(const uint8_t *buf, size_t size, int32_t frames_lost,
                                bool frame_recovered, void *user);
typedef void (*VPAudioFormatCallback)(uint32_t channels, uint32_t sample_rate, void *user);
/// Interleaved signed 16-bit PCM, `frames` samples per channel.
typedef void (*VPAudioFrameCallback)(const int16_t *pcm, size_t frames, void *user);
/// DualSense haptics as audio: interleaved stereo int16 at 3000 Hz (left and
/// right actuator), typically 30 frames (10 ms) per call. PS5 only.
typedef void (*VPHapticsCallback)(const int16_t *stereo_pcm, size_t frames, void *user);

typedef enum {
    VP_CODEC_H264 = 0,
    VP_CODEC_H265 = 1,
    VP_CODEC_H265_HDR = 2
} VPCodec;

typedef struct {
    const char *host;                       // IPv4/IPv6 literal or hostname
    bool ps5;
    uint8_t regist_key[VP_KEY_SIZE];        // from registration
    uint8_t morning[VP_KEY_SIZE];           // "rp_key" from registration
    uint8_t psn_account_id[VP_ACCOUNT_ID_SIZE];
    int resolution;                         // 360, 540, 720 or 1080
    int fps;                                // 30 or 60
    VPCodec codec;
    unsigned int bitrate_kbps;              // 0 = preset default
    VPEventCallback event_cb;
    VPVideoCallback video_cb;
    VPAudioFormatCallback audio_format_cb;
    VPAudioFrameCallback audio_frame_cb;
    VPLogCallback log_cb;
    VPHapticsCallback haptics_cb;           // may be NULL (then haptics fall back to rumble events)
    void *user;                             // passed to every callback
} VPSessionConfig;

typedef struct {
    uint32_t buttons;       // VP_BUTTON_* bit mask
    uint8_t l2;             // 0...255
    uint8_t r2;
    int16_t left_x, left_y; // -32768...32767, +y is DOWN (PlayStation convention)
    int16_t right_x, right_y;
    /// Touchpad, up to two fingers. Coordinates in PS space: x 0...1919,
    /// y 0...941 (down positive). The shim tracks finger ids itself.
    bool touch_down[2];
    uint16_t touch_x[2];
    uint16_t touch_y[2];
    /// Motion in the PlayStation frame (+Y up, +Z toward the player):
    /// gyro in rad/s, accel in g (reaction force, so ~+1 on Y at rest).
    /// Orientation is integrated inside the shim.
    bool has_motion;
    float gyro[3];
    float accel[3];
} VPControllerState;

enum {
    VP_BUTTON_CROSS = 1 << 0,
    VP_BUTTON_CIRCLE = 1 << 1,
    VP_BUTTON_SQUARE = 1 << 2,
    VP_BUTTON_TRIANGLE = 1 << 3,
    VP_BUTTON_DPAD_LEFT = 1 << 4,
    VP_BUTTON_DPAD_RIGHT = 1 << 5,
    VP_BUTTON_DPAD_UP = 1 << 6,
    VP_BUTTON_DPAD_DOWN = 1 << 7,
    VP_BUTTON_L1 = 1 << 8,
    VP_BUTTON_R1 = 1 << 9,
    VP_BUTTON_L3 = 1 << 10,
    VP_BUTTON_R3 = 1 << 11,
    VP_BUTTON_OPTIONS = 1 << 12,
    VP_BUTTON_SHARE = 1 << 13,   // "Create" on DualSense
    VP_BUTTON_TOUCHPAD = 1 << 14,
    VP_BUTTON_PS = 1 << 15
};

/// Returns NULL on failure and writes the error to *error_out (may be NULL).
VPSession *vp_session_create(const VPSessionConfig *config, int *error_out);
int vp_session_start(VPSession *session);
/// Asks the session to end. Callbacks may still fire until destroy returns.
void vp_session_stop(VPSession *session);
/// Stops (if needed), joins the session thread and frees everything.
void vp_session_destroy(VPSession *session);
int vp_session_set_controller(VPSession *session, const VPControllerState *state);
int vp_session_set_login_pin(VPSession *session, const char *pin);
int vp_session_request_idr(VPSession *session);
int vp_session_go_home(VPSession *session);
int vp_session_sleep_console(VPSession *session);

typedef struct {
    double bitrate_mbps;     // console-measured stream bitrate
    double rtt_ms;           // round-trip time measured when the session started
    double packet_loss;      // congestion-control loss ratio 0...1
} VPStreamStats;

/// Cheap, lock-free best-effort read. Returns 0 on success.
int vp_session_get_stats(VPSession *session, VPStreamStats *out);

// MARK: - Registration (pairing with the PIN from
// PS5: Settings > System > Remote Play > Link Device)

typedef enum {
    VP_REGIST_SUCCESS = 0,
    VP_REGIST_FAILED = 1,
    VP_REGIST_CANCELED = 2
} VPRegistResult;

typedef struct {
    bool ps5;
    char nickname[33];
    uint8_t regist_key[VP_KEY_SIZE];
    uint8_t morning[VP_KEY_SIZE];
    uint8_t mac[6];
} VPRegisteredHost;

typedef void (*VPRegistCallback)(VPRegistResult result, const VPRegisteredHost *host, void *user);

VPRegist *vp_regist_start(const char *host, bool ps5, bool broadcast,
                          const uint8_t psn_account_id[VP_ACCOUNT_ID_SIZE], uint32_t pin,
                          VPRegistCallback cb, VPLogCallback log_cb, void *user, int *error_out);
void vp_regist_destroy(VPRegist *regist);

// MARK: - Wake from rest mode

int vp_wakeup(const char *host, const uint8_t regist_key[VP_KEY_SIZE], bool ps5);

// MARK: - Discovery

typedef enum {
    VP_HOST_UNKNOWN = 0,
    VP_HOST_READY = 1,
    VP_HOST_STANDBY = 2
} VPHostState;

typedef struct {
    VPHostState state;
    bool ps5;
    const char *host_addr;
    const char *host_name;
    const char *host_id;
    const char *running_app_name;
} VPDiscoveredHost;

/// Strings are valid during the callback only.
typedef void (*VPDiscoveryCallback)(const VPDiscoveredHost *hosts, size_t count, void *user);

/// unicast_host == NULL broadcasts on the LAN (needs the multicast networking
/// entitlement on visionOS); a host address polls that one console.
VPDiscovery *vp_discovery_start(const char *unicast_host, VPDiscoveryCallback cb,
                                VPLogCallback log_cb, void *user);
void vp_discovery_destroy(VPDiscovery *discovery);

#ifdef __cplusplus
}
#endif

#endif // VP_CHIAKI_H
