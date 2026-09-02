/*
 * Copyright (c) 2026 EKS Inc.
 * Created by Ryu.
 * SPDX-License-Identifier: LicenseRef-EKS-NonCommercial-1.0
 *
 * LED Bluetooth status effect using PWM.
 * Shows profile and connection status colors.
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/pwm.h>
#include <zephyr/logging/log.h>
#include <zmk/split/transport/central.h>
#include <zmk/split/transport/peripheral.h>
#include <zmk/split/transport/types.h>
#if IS_ENABLED(CONFIG_ZMK_USB)
#include <zmk/usb.h>
#endif

LOG_MODULE_REGISTER(led_breath, CONFIG_LOG_DEFAULT_LEVEL);

#define BREATH_STEP_MS    CONFIG_MODU_LED_BREATH_STEP_MS
#define BREATH_SCALE      10000u  /* brightness resolution (0..BREATH_SCALE) */
#define SLOW_BLINK_MS     1200u
#define FAST_BLINK_MS     250u
#define BOOT_RED_MS       1500u

__weak int zmk_ble_active_profile_index(void) { return 0; }
__weak bool zmk_ble_active_profile_is_open(void) { return true; }
__weak bool zmk_split_bt_peripheral_is_connected(void) { return false; }
__weak bool zmk_split_bt_peripheral_is_bonded(void) { return false; }

#if IS_ENABLED(CONFIG_ZMK_SPLIT_ROLE_CENTRAL)
extern const struct zmk_split_transport_central *active_transport;
#else
extern const struct zmk_split_transport_peripheral *active_transport;
#endif

#define MODU_IS_LEFT_SHIELD  IS_ENABLED(CONFIG_SHIELD_MODU_LEFT)
#define MODU_IS_RIGHT_SHIELD IS_ENABLED(CONFIG_SHIELD_MODU_RIGHT)

/* LED PWM device nodes */
static const struct pwm_dt_spec leds[] = {
#if DT_NODE_EXISTS(DT_ALIAS(led_status1))
    PWM_DT_SPEC_GET(DT_ALIAS(led_status1)),
#endif
#if DT_NODE_EXISTS(DT_ALIAS(led_status2))
    PWM_DT_SPEC_GET(DT_ALIAS(led_status2)),
#endif
#if DT_NODE_EXISTS(DT_ALIAS(led_status3))
    PWM_DT_SPEC_GET(DT_ALIAS(led_status3)),
#endif
};

#define NUM_LEDS ARRAY_SIZE(leds)

static struct k_work_delayable breath_work;
static uint32_t breath_tick;

#if MODU_IS_LEFT_SHIELD
static const uint16_t white_color[3] = {BREATH_SCALE, BREATH_SCALE, BREATH_SCALE};
#endif

#if MODU_IS_RIGHT_SHIELD
/*
 * Right channel order is blue, green, red - the same as the left half, not the
 * green/blue/red this file assumed until 2026-09-03. Measured, not derived:
 * with the old values a connected right half lit blue, and only index 0 being
 * blue explains that. The two reds below were unaffected either way, which is
 * why the mistake survived - it only ever swapped green and blue.
 */
static const uint16_t right_unset_color[3] = {BREATH_SCALE, 0, 0};        /* blue */
static const uint16_t right_connected_color[3] = {0, BREATH_SCALE, 0};    /* green */
static const uint16_t right_disconnected_color[3] = {0, 0, BREATH_SCALE}; /* red */
#else
/* Hardware PWM channel order is blue, green, red. */
static const uint16_t profile_colors[][3] = {
    {7200, BREATH_SCALE, 0},         /* Profile 1: mint */
    {BREATH_SCALE, 3000, 8500},      /* Profile 2: light purple */
    {0, 3600, BREATH_SCALE},         /* Profile 3: orange */
};
#endif

static const uint16_t boot_color[3] = {0, 0, BREATH_SCALE};
#if !MODU_IS_RIGHT_SHIELD
static const uint16_t split_unset_color[3] = {BREATH_SCALE, 0, 0};
#endif

#if MODU_IS_LEFT_SHIELD
static bool left_usb_connected(void)
{
#if MODU_IS_LEFT_SHIELD && IS_ENABLED(CONFIG_ZMK_USB)
    return zmk_usb_is_powered();
#else
    return false;
#endif
}
#endif

static uint32_t blink_level(uint32_t tick, uint32_t blink_ms)
{
    uint32_t steps = blink_ms / BREATH_STEP_MS;

    if (steps < 2) {
        steps = 2;
    }

    return (tick % steps) < (steps / 2) ? BREATH_SCALE : 0;
}

#if MODU_IS_RIGHT_SHIELD
static bool split_transport_connected(void)
{
#if IS_ENABLED(CONFIG_ZMK_SPLIT_ROLE_CENTRAL)
    if (!active_transport || !active_transport->api) {
        return false;
    }

    if (!active_transport->api->get_status) {
        return true;
    }

    struct zmk_split_transport_status status = active_transport->api->get_status();

    return status.available && status.enabled &&
           status.connections == ZMK_SPLIT_TRANSPORT_CONNECTIONS_STATUS_ALL_CONNECTED;
#else
    if (!active_transport || !active_transport->api) {
        return zmk_split_bt_peripheral_is_connected();
    }

    if (!active_transport->api->get_status) {
        return true;
    }

    {
        struct zmk_split_transport_status status = active_transport->api->get_status();

        return status.available && status.enabled &&
               status.connections == ZMK_SPLIT_TRANSPORT_CONNECTIONS_STATUS_ALL_CONNECTED;
    }
#endif
}
#endif

static bool split_setup_done(void)
{
#if IS_ENABLED(CONFIG_ZMK_SPLIT_ROLE_CENTRAL)
    if (!active_transport || !active_transport->api) {
        return false;
    }

    if (!active_transport->api->get_status) {
        return true;
    }

    struct zmk_split_transport_status status = active_transport->api->get_status();

    return status.available;
#else
    return zmk_split_bt_peripheral_is_bonded();
#endif
}

static void set_led_channel(int channel, uint32_t level)
{
    if (channel >= NUM_LEDS || !device_is_ready(leds[channel].dev)) {
        return;
    }

    uint32_t pulse = (uint32_t)((uint64_t)leds[channel].period *
                                (BREATH_SCALE - level) / BREATH_SCALE);
    pwm_set_pulse_dt(&leds[channel], pulse);
}

static void breath_work_handler(struct k_work *work)
{
#if MODU_IS_RIGHT_SHIELD
    bool split_setup = split_setup_done();
    bool split_ready = split_transport_connected();
    bool booting = breath_tick * BREATH_STEP_MS < BOOT_RED_MS;
    uint32_t level = split_setup ? BREATH_SCALE : blink_level(breath_tick, FAST_BLINK_MS);
#else
    bool split_setup = split_setup_done();
    bool force_white = left_usb_connected();
    bool booting = breath_tick * BREATH_STEP_MS < BOOT_RED_MS;
    uint8_t profile = zmk_ble_active_profile_index() % ARRAY_SIZE(profile_colors);
    uint32_t level = !split_setup ? blink_level(breath_tick, FAST_BLINK_MS)
                                  : zmk_ble_active_profile_is_open()
                                        ? blink_level(breath_tick, SLOW_BLINK_MS)
                                                      : BREATH_SCALE;
#endif

    for (int i = 0; i < NUM_LEDS; i++) {
#if MODU_IS_RIGHT_SHIELD
        uint32_t channel = i < 3 ? (!split_setup ? right_unset_color[i]
                                                 : booting ? boot_color[i]
                                                           : split_ready ? right_connected_color[i]
                                                                         : right_disconnected_color[i])
                                 : BREATH_SCALE;
        uint32_t color_level = (split_setup && booting) ? channel
                                       : (uint32_t)((uint64_t)level * channel / BREATH_SCALE);
#else
        uint32_t channel = i < 3 ? (force_white ? white_color[i]
                                                : !split_setup ? split_unset_color[i]
                                                               : booting ? boot_color[i]
                                                                         : profile_colors[profile][i])
                                 : BREATH_SCALE;
        uint32_t color_level = force_white || (split_setup && booting) ? channel
                                       : (uint32_t)((uint64_t)level * channel / BREATH_SCALE);
#endif
        set_led_channel(i, color_level);
    }

    breath_tick++;
    k_work_schedule(&breath_work, K_MSEC(BREATH_STEP_MS));
}

static int led_breath_init(void)
{
    for (int i = 0; i < NUM_LEDS; i++) {
        if (!device_is_ready(leds[i].dev)) {
            LOG_WRN("LED %d PWM device not ready", i);
        }
    }

    breath_tick = 0;
    k_work_init_delayable(&breath_work, breath_work_handler);
    k_work_schedule(&breath_work, K_NO_WAIT);

    LOG_INF("LED status effect started (%d LEDs)", NUM_LEDS);
    return 0;
}

SYS_INIT(led_breath_init, APPLICATION, 99);
