// SPDX-License-Identifier: GPL-2.0

#include <diag/common.h>
#include <tests/test.h>
#include <tests/vboot/common.h>
#include <tests/vboot/ui/common.h>
#include <mocks/callbacks.h>
#include <mocks/util/commonparams.h>
#include <vb2_api.h>
#include <vboot/stages.h>
#include <vboot/util/commonparams.h>

/* Mock functions */
int ui_is_lid_open(void)
{
	return mock();
}

/* Tests */
struct ui_context test_ui_ctx;
struct vb2_kernel_params test_kparams;

static int setup_context(void **state)
{
	memset(&test_ui_ctx, 0, sizeof(test_ui_ctx));
	reset_mock_workbuf = 1;

	test_ui_ctx.ctx = vboot_get_context();
	set_boot_mode(test_ui_ctx.ctx, VB2_BOOT_MODE_DIAGNOSTICS);

	memset(&test_kparams, 0, sizeof(test_kparams));
	test_ui_ctx.kparams = &test_kparams;
	*state = &test_ui_ctx;

	return 0;
}

static void test_diagnostics_screen_disabled_and_hidden(void **state)
{
	struct ui_context *ui = *state;

	WILL_CLOSE_LID_IN(3);
	EXPECT_UI_DISPLAY(UI_SCREEN_DIAGNOSTICS, MOCK_IGNORE, MOCK_IGNORE,
			  0x0, 0x0);
	will_return_maybe(ui_keyboard_read, 0);
	will_return_maybe(vb2api_gbb_get_flags, 0);
	will_return_always(diag_storage_test_supported, 1);
	will_return_maybe(memory_test_init, DIAG_TEST_SUCCESS);

	assert_int_equal(vboot_select_and_load_kernel(ui->ctx, ui->kparams),
			 VB2_REQUEST_SHUTDOWN);
}

static void test_diagnostics_screen(void **state)
{
	struct ui_context *ui = *state;

	EXPECT_UI_DISPLAY(UI_SCREEN_DIAGNOSTICS, MOCK_IGNORE, 1);
	/* #0: Language menu */
	WILL_PRESS_KEY(UI_KEY_UP, 0);
	WILL_PRESS_KEY(UI_KEY_ENTER, 0);
	WILL_PRESS_KEY(UI_KEY_ESC, 0);
	EXPECT_UI_DISPLAY(UI_SCREEN_DIAGNOSTICS, MOCK_IGNORE, 0);
	EXPECT_UI_DISPLAY(UI_SCREEN_LANGUAGE_SELECT);
	EXPECT_UI_DISPLAY_ANY();
	/* #1: Storage health screen */
	WILL_PRESS_KEY(UI_KEY_DOWN, 0);
	WILL_PRESS_KEY(UI_KEY_ENTER, 0);
	WILL_PRESS_KEY(UI_KEY_ESC, 0);
	EXPECT_UI_DISPLAY(UI_SCREEN_DIAGNOSTICS, MOCK_IGNORE, 1);
	EXPECT_UI_DISPLAY(UI_SCREEN_DIAGNOSTICS_STORAGE_HEALTH);
	EXPECT_UI_DISPLAY_ANY();
	/* #2: Short storage self-test screen */
	WILL_PRESS_KEY(UI_KEY_DOWN, 0);
	WILL_PRESS_KEY(UI_KEY_ENTER, 0);
	WILL_PRESS_KEY(UI_KEY_ESC, 0);
	EXPECT_UI_DISPLAY(UI_SCREEN_DIAGNOSTICS, MOCK_IGNORE, 2);
	EXPECT_UI_DISPLAY(UI_SCREEN_DIAGNOSTICS_STORAGE_TEST_SHORT);
	EXPECT_UI_DISPLAY_ANY();
	/* #3: Extended storage self-test screen */
	WILL_PRESS_KEY(UI_KEY_DOWN, 0);
	WILL_PRESS_KEY(UI_KEY_ENTER, 0);
	WILL_PRESS_KEY(UI_KEY_ESC, 0);
	EXPECT_UI_DISPLAY(UI_SCREEN_DIAGNOSTICS, MOCK_IGNORE, 3);
	EXPECT_UI_DISPLAY(UI_SCREEN_DIAGNOSTICS_STORAGE_TEST_EXTENDED);
	EXPECT_UI_DISPLAY_ANY();
	/* #4: Quick memory test screen */
	WILL_PRESS_KEY(UI_KEY_DOWN, 0);
	WILL_PRESS_KEY(UI_KEY_ENTER, 0);
	WILL_PRESS_KEY(UI_KEY_ESC, 0);
	EXPECT_UI_DISPLAY(UI_SCREEN_DIAGNOSTICS, MOCK_IGNORE, 4);
	EXPECT_UI_DISPLAY(UI_SCREEN_DIAGNOSTICS_MEMORY_QUICK);
	EXPECT_UI_DISPLAY_ANY();
	/* #5: Full memory test screen */
	WILL_PRESS_KEY(UI_KEY_DOWN, 0);
	WILL_PRESS_KEY(UI_KEY_ENTER, 0);
	WILL_PRESS_KEY(UI_KEY_ESC, 0);
	EXPECT_UI_DISPLAY(UI_SCREEN_DIAGNOSTICS, MOCK_IGNORE, 5);
	EXPECT_UI_DISPLAY(UI_SCREEN_DIAGNOSTICS_MEMORY_FULL);
	EXPECT_UI_DISPLAY_ANY();
	/* #6: Power off (End of menu) */
	WILL_PRESS_KEY(UI_KEY_DOWN, 0);
	WILL_PRESS_KEY(UI_KEY_ENTER, 0);
	EXPECT_UI_DISPLAY(UI_SCREEN_DIAGNOSTICS, MOCK_IGNORE, 6);

	will_return_maybe(ui_is_lid_open, 1);
	will_return_maybe(ui_keyboard_read, 0);
	will_return_maybe(vb2api_gbb_get_flags, 0);
	will_return_maybe(ui_get_locale_count, 10);
	EXPECT_UI_LOG_INIT_ANY_ALWAYS();
	WILL_CALL_UI_LOG_INIT_ALWAYS(1);
	will_return_always(diag_storage_test_supported, 1);
	will_return_always(diag_dump_storage_test_log, DIAG_TEST_SUCCESS);
	will_return_always(diag_storage_test_control, DIAG_TEST_SUCCESS);
	will_return_always(memory_test_init, DIAG_TEST_SUCCESS);
	will_return_always(memory_test_run, DIAG_TEST_SUCCESS);

	assert_int_equal(vboot_select_and_load_kernel(ui->ctx, ui->kparams),
			 VB2_REQUEST_SHUTDOWN);
}

static void test_diagnostics_screen_no_storage_self_test(void **state)
{
	struct ui_context *ui = *state;

	WILL_CLOSE_LID_IN(3);
	will_return_always(diag_storage_test_supported, 0);
	will_return_maybe(ui_keyboard_read, 0);
	will_return_maybe(vb2api_gbb_get_flags, 0);
	EXPECT_UI_DISPLAY(UI_SCREEN_DIAGNOSTICS, MOCK_IGNORE, MOCK_IGNORE,
			  0xc, 0x0); /* 0xc = 0b1100 */

	assert_int_equal(vboot_select_and_load_kernel(ui->ctx, ui->kparams),
			 VB2_REQUEST_SHUTDOWN);
}

#define UI_TEST(test_function_name) \
	cmocka_unit_test_setup(test_function_name, setup_context)

int main(void)
{
	const struct CMUnitTest tests[] = {
		UI_TEST(test_diagnostics_screen_disabled_and_hidden),
		UI_TEST(test_diagnostics_screen),
		UI_TEST(test_diagnostics_screen_no_storage_self_test),
	};
	return cmocka_run_group_tests(tests, NULL, NULL);
}