// SPDX-License-Identifier: GPL-2.0
/*
 * Copyright 2020 Google LLC.
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

#include "diag/health_info.h"
#include "diag/memory.h"
#include "diag/storage_test.h"
#include "drivers/ec/cros/ec.h"
#include "drivers/tpm/tpm.h"
#include "vboot/firmware_id.h"
#include "vboot/ui.h"

#define DEBUG_INFO_EXTRA_LENGTH 256

const char *vb2ex_get_debug_info(struct vb2_context *ctx)
{
	static char *buf;
	size_t buf_size;

	char *vboot_buf;
	char *tpm_str = NULL;
	char batt_pct_str[16];

	/* Check if cache exists. */
	if (buf)
		return buf;

	/* Debug info from the vboot context. */
	vboot_buf = vb2api_get_debug_info(ctx);

	buf_size = strlen(vboot_buf) + DEBUG_INFO_EXTRA_LENGTH + 1;
	buf = malloc(buf_size);
	if (buf == NULL) {
		printf("%s: Failed to malloc string buffer\n", __func__);
		free(vboot_buf);
		return NULL;
	}

	/* States owned by firmware. */
	if (CONFIG(MOCK_TPM))
		tpm_str = "MOCK TPM";
	else if (CONFIG(DRIVER_TPM))
		tpm_str = tpm_report_state();

	if (!tpm_str)
		tpm_str = "(unsupported)";

	if (!CONFIG(DRIVER_EC_CROS)) {
		strncpy(batt_pct_str, "(unsupported)", sizeof(batt_pct_str));
	} else {
		uint32_t batt_pct;
		if (cros_ec_read_batt_state_of_charge(&batt_pct))
			strncpy(batt_pct_str, "(read failure)",
				sizeof(batt_pct_str));
		else
			snprintf(batt_pct_str, sizeof(batt_pct_str),
				 "%u%%", batt_pct);
	}
	snprintf(buf, buf_size,
		 "%s\n"  /* vboot output does not include newline. */
		 "read-only firmware id: %s\n"
		 "active firmware id: %s\n"
		 "battery level: %s\n"
		 "TPM state: %s",
		 vboot_buf,
		 get_ro_fw_id(), get_active_fw_id(),
		 batt_pct_str, tpm_str);

	free(vboot_buf);

	buf[buf_size - 1] = '\0';
	printf("debug info: %s\n", buf);
	return buf;
}

const char *vb2ex_get_firmware_log(int reset)
{
	static char *buf;
	if (!buf || reset) {
		free(buf);
		buf = cbmem_console_snapshot();
		if (buf)
			printf("Read cbmem console: size=%zu\n", strlen(buf));
		else
			printf("Failed to read cbmem console\n");
	}
	return buf;
}

#define DEFAULT_DIAGNOSTIC_OUTPUT_SIZE (64 * KiB)

vb2_error_t vb2ex_diag_get_storage_health(const char **out)
{
	static char *buf;
	if (!buf)
		buf = malloc(DEFAULT_DIAGNOSTIC_OUTPUT_SIZE);
	*out = buf;
	if (!buf)
		return VB2_ERROR_UI_MEMORY_ALLOC;

	dump_all_health_info(buf, buf + DEFAULT_DIAGNOSTIC_OUTPUT_SIZE);

	return VB2_SUCCESS;
}

vb2_error_t vb2ex_diag_get_storage_test_log(const char **out)
{
	static char *buf;
	if (!buf)
		buf = malloc(DEFAULT_DIAGNOSTIC_OUTPUT_SIZE);
	*out = buf;
	if (!buf)
		return VB2_ERROR_UI_MEMORY_ALLOC;

	return diag_dump_storage_test_log(buf,
					  buf + DEFAULT_DIAGNOSTIC_OUTPUT_SIZE);
}

vb2_error_t vb2ex_diag_memory_quick_test(int reset, const char **out)
{
	*out = NULL;
	if (reset)
		VB2_TRY(memory_test_init(MEMORY_TEST_MODE_QUICK));
	return memory_test_run(out);
}

vb2_error_t vb2ex_diag_memory_full_test(int reset, const char **out)
{
	*out = NULL;
	if (reset)
		VB2_TRY(memory_test_init(MEMORY_TEST_MODE_FULL));
	return memory_test_run(out);
}
