/*
 * Copyright (c) 2026 EKS Inc.
 * Created by Ryu.
 * SPDX-License-Identifier: LicenseRef-EKS-NonCommercial-1.0
 *
 * Persists the OS mode overlay (mac_layer) across reboots.
 *
 * ZMK does not save layer state, so a `&tog` on the macOS overlay is lost on
 * every power cycle. This watches that one layer, stores its state in settings
 * and re-applies it once settings have been loaded.
 */

#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/settings/settings.h>

#include <zmk/event_manager.h>
#include <zmk/events/layer_state_changed.h>
#include <zmk/keymap.h>

LOG_MODULE_REGISTER(modu_os_mode, CONFIG_ZMK_LOG_LEVEL);

#define OS_MODE_LAYER ((zmk_keymap_layer_id_t)CONFIG_MODU_OS_MODE_LAYER)

#define OS_MODE_SETTINGS_SUBTREE "modu_os"
#define OS_MODE_SETTINGS_KEY "mac"
#define OS_MODE_SETTINGS_PATH OS_MODE_SETTINGS_SUBTREE "/" OS_MODE_SETTINGS_KEY

/* Last state we know about; also what gets written to settings. */
static bool os_mode_active;

/* Suppress the save that our own restore would otherwise trigger. */
static bool os_mode_restoring;

static void os_mode_save_work_handler(struct k_work *work) {
    int err = settings_save_one(OS_MODE_SETTINGS_PATH, &os_mode_active, sizeof(os_mode_active));
    if (err) {
        LOG_ERR("Failed to save OS mode (%d)", err);
    }
}

static K_WORK_DELAYABLE_DEFINE(os_mode_save_work, os_mode_save_work_handler);

static void os_mode_restore_work_handler(struct k_work *work) {
    os_mode_restoring = true;
    int err = zmk_keymap_layer_activate(OS_MODE_LAYER, true);
    os_mode_restoring = false;

    if (err) {
        LOG_ERR("Failed to restore OS mode layer %d (%d)", OS_MODE_LAYER, err);
    } else {
        LOG_INF("Restored OS mode layer %d", OS_MODE_LAYER);
    }
}

static K_WORK_DELAYABLE_DEFINE(os_mode_restore_work, os_mode_restore_work_handler);

static int os_mode_listener(const zmk_event_t *eh) {
    const struct zmk_layer_state_changed *ev = as_zmk_layer_state_changed(eh);

    if (!ev || ev->layer != OS_MODE_LAYER || os_mode_restoring) {
        return ZMK_EV_EVENT_BUBBLE;
    }

    if (ev->state == os_mode_active) {
        return ZMK_EV_EVENT_BUBBLE;
    }

    os_mode_active = ev->state;
    k_work_reschedule(&os_mode_save_work, K_MSEC(CONFIG_MODU_OS_MODE_SAVE_DEBOUNCE_MS));

    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(os_mode_listener, os_mode_listener);
ZMK_SUBSCRIPTION(os_mode_listener, zmk_layer_state_changed);

static int os_mode_settings_set(const char *name, size_t len, settings_read_cb read_cb,
                                void *cb_arg) {
    const char *next;

    if (!settings_name_steq(name, OS_MODE_SETTINGS_KEY, &next) || next) {
        return -ENOENT;
    }

    if (len != sizeof(os_mode_active)) {
        return -EINVAL;
    }

    int rc = read_cb(cb_arg, &os_mode_active, sizeof(os_mode_active));

    return MIN(rc, 0);
}

/*
 * Runs at the end of settings_load(), by which point the keymap is up. The
 * activation itself is deferred to the work queue so it is raised as a normal
 * event rather than from inside the settings machinery.
 */
static int os_mode_settings_commit(void) {
    if (os_mode_active) {
        k_work_reschedule(&os_mode_restore_work, K_NO_WAIT);
    }

    return 0;
}

SETTINGS_STATIC_HANDLER_DEFINE(modu_os_mode, OS_MODE_SETTINGS_SUBTREE, NULL, os_mode_settings_set,
                               os_mode_settings_commit, NULL);
