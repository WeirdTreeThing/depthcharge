// SPDX-License-Identifier: GPL-2.0
/*
 * Copyright 2020 Google Inc.
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

#include "vboot/ui.h"

#define UI_FILES(a) ((struct ui_files) {	\
	.files = a,				\
	.count = ARRAY_SIZE(a),			\
})

/******************************************************************************/
/* VB2_SCREEN_BLANK */

static vb2_error_t draw_blank(const struct ui_screen_info *screen,
			      const struct ui_state *state,
			      const struct ui_state *prev_state)
{
	clear_screen(&ui_color_bg);
	return VB2_SUCCESS;
}

static const struct ui_screen_info blank_screen = {
	.id = VB2_SCREEN_BLANK,
	.draw = draw_blank,
	.mesg = NULL,
};

/******************************************************************************/
/* VB2_SCREEN_FIRMWARE_SYNC */

static const char *const firmware_sync_desc[] = {
	"firmware_sync_desc.bmp",
};

static const struct ui_screen_info firmware_sync_screen = {
	.id = VB2_SCREEN_FIRMWARE_SYNC,
	.icon = UI_ICON_TYPE_NONE,
	.title = "firmware_sync_title.bmp",
	.desc = UI_FILES(firmware_sync_desc),
	.mesg = "Please do not power off your device.\n"
		"Your system is applying a critical update.",
};

/******************************************************************************/
/* VB2_SCREEN_RECOVERY_SELECT */

static const char *const recovery_select_desc[] = {
	"rec_sel_desc0.bmp",
	"rec_sel_desc1.bmp",
};

static const char *const recovery_select_menu[] = {
	"btn_rec_by_phone.bmp",
	"btn_rec_by_disk.bmp",
};

static const struct ui_screen_info recovery_select_screen = {
	.id = VB2_SCREEN_RECOVERY_SELECT,
	.icon = UI_ICON_TYPE_INFO,
	.title = "rec_sel_title.bmp",
	.desc = UI_FILES(recovery_select_desc),
	.menu = UI_FILES(recovery_select_menu),
	.mesg = "Select how you'd like to recover.\n"
		"You can recover using a USB drive or an SD card.",
};

/******************************************************************************/
/*
 * TODO(chromium:1035800): Refactor UI code across vboot and depthcharge.
 * Currently vboot and depthcharge maintain their own copies of menus/screens.
 * vboot detects keyboard input and controls the navigation among different menu
 * items and screens, while depthcharge performs the actual rendering of each
 * screen, based on the menu information passed from vboot.
 */
static const struct ui_screen_info *const screens[] = {
	&blank_screen,
	&firmware_sync_screen,
	&recovery_select_screen,
};

const struct ui_screen_info *ui_get_screen_info(enum vb2_screen screen_id)
{
	int i;
	for (i = 0; i < ARRAY_SIZE(screens); i++) {
		if (screens[i]->id == screen_id)
			return screens[i];
	}
	return NULL;
}
