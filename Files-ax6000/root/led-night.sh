#!/bin/sh
echo 0 > /sys/class/leds/blue:power/brightness
echo 0 > /sys/class/leds/yellow:power/brightness
echo 0 > /sys/class/leds/blue:wan-online/brightness
echo 0 > /sys/class/leds/yellow:wan/brightness
echo 0 > /sys/class/leds/green:lan/brightness
echo 0 > /sys/class/leds/green:wlan/brightness
