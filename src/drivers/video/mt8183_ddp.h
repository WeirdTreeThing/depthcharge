/*
 * Copyright 2019 Google Inc.
 *
 * See file CREDITS for list of people who contributed to this
 * project.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation; either version 2 of
 * the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but without any warranty; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 */

#ifndef __DRIVERS_VIDEO_MT8183_H__
#define __DRIVERS_VIDEO_MT8183_H__

#include "drivers/video/display.h"

DisplayOps *new_mt8183_display(int (*backlight_update)
			       (DisplayOps *me, uint8_t enable));

#endif /* __DRIVERS_VIDEO_MT8183_H__ */