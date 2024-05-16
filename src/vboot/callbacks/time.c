/*
 * Copyright 2012 Google Inc.
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

#include <libpayload.h>
#include <vb2_api.h>
#include <vboot_api.h>

#include "drivers/sound/sound.h"

uint64_t VbExGetTimer(void)
{
	static uint64_t start = 0;
	if (!start)
		start = timer_us(0);
	return timer_us(start);
}

void VbExSleepMs(uint32_t msec)
{
	mdelay(msec);
}

vb2_error_t VbExBeep(uint32_t msec, uint32_t frequency)
{
	return VB2_SUCCESS;
}
