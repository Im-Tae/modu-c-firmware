if(CONFIG_MODU_LED_BREATH)
  add_subdirectory(src/led_breath)
endif()

if(CONFIG_MODU_ALT_THUMB_KSCAN)
  add_subdirectory(src/alt_thumb_kscan)
endif()

if(CONFIG_MODU_OS_MODE_PERSIST)
  add_subdirectory(src/os_mode)
endif()
