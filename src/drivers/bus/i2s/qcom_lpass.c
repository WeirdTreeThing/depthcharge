/*
 * This file is part of the depthcharge project.
 *
 * Copyright (c) 2019-2020 Qualcomm Technologies
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 and
 * only version 2 as published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 */
#include <libpayload.h>
#include <stdint.h>
#include <inttypes.h>
#include <malloc.h>
#include "drivers/bus/i2s/qcom_lpass.h"

#define DISABLE				0x0
#define ENABLE				0x1
#define RESET				(0x1 << 31)

#define DIG_PLL_L_VALUE			0x20
#define PLLOUT_MAIN			1
#define PLLOUT_ODD			(0x1 << 2)
#define POST_DIV_EVEN			(0x1 << 8)
#define POST_DIV_ODD			(0x5 << 12)
#define PLL_LOCK_DET			(0x1 << 31)
#define PLL_OUT_CTRL			0x1

#define FINE_LOCK_DET			1
#define CALIB_CTRL			(0x2 << 1)
#define SCALE_FREQ_RESTART		(0x1 << 11)
#define RESERVE_BIT			(0x1 << 14)

#define FWD_GAIN_KFN			7
#define FWD_GAIN_SLE			(0x6 << 4)
#define FINE_LOCK_DET_THR		(0x4 << 11)

#define PLL_SET_HW			(0x7C)

#define SRC_DIV				0x9
#define CFG_SRC_SEL			(0x5 << 8)
#define CFG_MODE			(0x2 << 12)

#define FIFO_WATERMARK			(0x7 << 1)
#define AUDIO_INTF_SHIFT		(0x2 << 12)
#define WPSCNT				(0x1 << 16)
#define BURST_EN			(0x1 << 20)
#define DYNAMIC_CLK_EN			(0x1 << 21)

#define LONG_RATE_SHIFT			(0xF << 18)
#define SPKR_EN				(0x1 << 16)
#define SPKR_MODE			(0x1 << 11)

#define LPAIF_IRQ_BITSTRIDE		3
#define LPAIF_IRQ_PER(chan)		(1 << (LPAIF_IRQ_BITSTRIDE * (chan)))
#define LPAIF_IRQ_ERR(chan)		(4 << (LPAIF_IRQ_BITSTRIDE * (chan)))

#define LPAIF_IRQ_ALL(chan)		(7 << (LPAIF_IRQ_BITSTRIDE * (chan)))

#define GDSC_ENABLE_BIT_MASK		BIT(31)
#define GDSC_RETAIN_FF_ENABLE		BIT(11)

static void lpass_pll_configure(LpassPllSet *pll_reg)
{
	uint64_t start;
	write32(&pll_reg->dig_pll_mode, DISABLE);
	write32(&pll_reg->dig_pll_l, DIG_PLL_L_VALUE);
	write32(&pll_reg->dig_pll_cal, DIG_PLL_L_VALUE);

	write32(&pll_reg->dig_pll_user_ctl, PLLOUT_MAIN | PLLOUT_ODD |
				POST_DIV_EVEN | POST_DIV_ODD);

	write32(&pll_reg->dig_pll_user_ctl_u, FINE_LOCK_DET | CALIB_CTRL |
				SCALE_FREQ_RESTART | RESERVE_BIT);

	write32(&pll_reg->dig_pll_config_ctl_u, FWD_GAIN_KFN | FWD_GAIN_SLE
				| FINE_LOCK_DET_THR);

	write32(&pll_reg->dig_pll_mode, PLL_SET_HW);
	write32(&pll_reg->dig_pll_opmode, ENABLE);
	write32(&pll_reg->dig_pll_mode, PLL_SET_HW | ENABLE);

	start = timer_us(0);
	while ((((read32(&pll_reg->dig_pll_mode) & PLL_LOCK_DET)) >> 0x1f)
						!= PLL_OUT_CTRL) {
		if (timer_us(start) > 5 * USECS_PER_MSEC) {
			printf("ERROR: lpass audio PLL did not lock!\n");
			break;
		}
	}
}

/*
 * Enable and check for timeout while polling the GDSC enable status
 * Returns: 0 on success, -1 value on error
 */
static int enable_and_poll_gdsc_status(u32 *gdsc_addr)
{
	uint64_t start;

	clrbits_le32(gdsc_addr, ENABLE);
	start = timer_us(0);
	while (!(read32(gdsc_addr) & GDSC_ENABLE_BIT_MASK)) {
		if (timer_us(start) > 100)
			return -1;
	}

	return 0;
}

static void lpass_init_registers(LpassI2s *bus)
{
	LpassReg *lpass_reg = bus->lpass_regs;

	if (enable_and_poll_gdsc_status(&lpass_reg->core_hm_gdscr))
		printf("Failed to enable core_hm_gdscr.\n");

	if (enable_and_poll_gdsc_status(&lpass_reg->audio_hm_gdscr))
		printf("Failed to enable audio_hm_gdscr.\n");

	if (enable_and_poll_gdsc_status(&lpass_reg->pdc_hm_gdscr))
		printf("Failed to enable pdc_hm_gdscr.\n");

	setbits_le32(&lpass_reg->core_hm_gdscr, GDSC_RETAIN_FF_ENABLE);

	setbits_le32(&lpass_reg->ext_mclk0, ENABLE);
	setbits_le32(&lpass_reg->core, ENABLE);
	setbits_le32(&lpass_reg->core_ext_mclk0, ENABLE);
	setbits_le32(&lpass_reg->sysnoc_mport, ENABLE);
	setbits_le32(&lpass_reg->sysnoc_sway, ENABLE);

	lpass_pll_configure(&lpass_reg->pll_config);

	write32(&lpass_reg->bit_cbcr[bus->device_id].lpaif_cfg_rgcr, SRC_DIV |
				CFG_SRC_SEL | CFG_MODE);

	write32(&lpass_reg->bit_cbcr[bus->device_id].lpaif_cmd_rgcr, ENABLE);
}

static int lpass_devsetup(LpassI2s *bus, uintptr_t buffer, uint32_t length)
{

	LpassReg *lpass_reg = bus->lpass_regs;

	write32(&lpass_reg->lmm[bus->device_id].mode_mux, DISABLE);

	/* Clear Read DMA registers */
	write32(&lpass_reg->dma_rd_reg[bus->device_id].rddma_ctl, DISABLE);
	write32(&lpass_reg->dma_rd_reg[bus->device_id].rddma_base, DISABLE);
	write32(&lpass_reg->dma_rd_reg[bus->device_id].rddma_buf_len, DISABLE);
	write32(&lpass_reg->dma_rd_reg[bus->device_id].rddma_per_len, DISABLE);

	/* Reset control register */
	write32(&lpass_reg->dma_rd_reg[bus->device_id].rddma_ctl, RESET);
	write32(&lpass_reg->dma_rd_reg[bus->device_id].rddma_ctl, DISABLE);

	/* Congfigure I2S for playback */
	write32(&lpass_reg->i2s_reg[bus->device_id].pcm_i2s_sel, DISABLE);


	write32(&lpass_reg->i2s_reg[bus->device_id].i2s_ctl, SPKR_MODE |
				LONG_RATE_SHIFT | RESET);

	clrbits_le32(&lpass_reg->i2s_reg[bus->device_id].i2s_ctl, RESET);

	/* Configure Read DMA registers */
	write32(&lpass_reg->dma_rd_reg[bus->device_id].rddma_base, buffer);
	write32(&lpass_reg->dma_rd_reg[bus->device_id].rddma_buf_len,
								length-1);
	write32(&lpass_reg->dma_rd_reg[bus->device_id].rddma_per_len,
							 (length / 2)-1);

	write32(&lpass_reg->dma_rd_reg[bus->device_id].rddma_ctl, WPSCNT |
				FIFO_WATERMARK | AUDIO_INTF_SHIFT |
				BURST_EN | DYNAMIC_CLK_EN);

	setbits_le32(&lpass_reg->dma_rd_reg[bus->device_id].rddma_ctl,
						ENABLE);
	write32(&lpass_reg->irq_reg[bus->device_id].irq_en,
						LPAIF_IRQ_ALL(bus->device_id));

	return 0;
}

static int lpass_set_bitclock(LpassI2s *bus)
{
	LpassReg *lpass_reg = bus->lpass_regs;
	uint32_t data_m = 0;
	uint32_t data_n = 0;
	uint32_t data_d = 0;

	switch (bus->bclk_rate) {
	case 768000: /* 0.768 MHz */
		data_m = 1;
		data_n = 0xff60;
		data_d = 0xff5f;
		break;
	case 1152000: /* 1.152 MHz */
		data_m = 1;
		data_n = 0xff9e;
		data_d = 0xff9d;
		break;
	case 1536000: /* 1.536 MHz */
		data_m = 1;
		data_n = 0xffb0;
		data_d = 0xffaf;
		break;
	case 2304000: /* 2.304 MHz */
		data_m = 1;
		data_n = 0xffcf;
		data_d = 0xffce;
		break;
	case 3072000: /* 3.072 MHz */
		data_m = 1;
		data_n = 0xffd8;
		data_d = 0xffd7;
		break;
	default:
		printf("unsupported clock frequency = %d\n", bus->bclk_rate);
		return 1;
	}

	write32(&lpass_reg->bit_cbcr[bus->device_id].lpaif_m, data_m);
	write32(&lpass_reg->bit_cbcr[bus->device_id].lpaif_n, data_n);
	write32(&lpass_reg->bit_cbcr[bus->device_id].lpaif_d, data_d);

	write32(&lpass_reg->bit_cbcr[bus->device_id].lpaif_cfg_rgcr,
			CFG_MODE | CFG_SRC_SEL);

	write32(&lpass_reg->bit_cbcr[bus->device_id].lpaif_cmd_rgcr, ENABLE);

	return 0;
}
static int lpass_i2s_send(I2sOps *me, uint32_t *data, unsigned int length)
{
	LpassI2s *bus = container_of(me, LpassI2s, ops);
	LpassReg *lpass_reg = bus->lpass_regs;
	uint32_t *buffer;
	uint32_t bus_length = length * sizeof(uint32_t);
	int irq_status;
	int ret = 0;

	if (!bus->initialized) {
		lpass_init_registers(bus);
		if (lpass_set_bitclock(bus))
			return 1;
		bus->initialized = 1;
	}

	/* 16-byte aligned DMA buffer */
	buffer = dma_memalign(16, bus_length);
	memcpy(buffer, data, bus_length);

	lpass_devsetup(bus, (uintptr_t)buffer, length);


	/* Play tone for playback_time_ms */
	write32(&lpass_reg->bit_cbcr[bus->device_id].ibit_cbcr, ENABLE);
	setbits_le32(&lpass_reg->i2s_reg[bus->device_id].i2s_ctl, SPKR_EN);
	irq_status = read32(&lpass_reg->irq_reg[bus->device_id].irq_raw_stat);
	while ( irq_status != LPAIF_IRQ_PER(bus->device_id)) {
		if( irq_status ==  LPAIF_IRQ_ERR(bus->device_id)) {
			ret = 1;
			break;
		}
		irq_status = read32(&lpass_reg->irq_reg[bus->device_id].
								irq_raw_stat);
	}

	clrbits_le32(&lpass_reg->i2s_reg[bus->device_id].i2s_ctl, SPKR_EN);
	write32(&lpass_reg->irq_reg[bus->device_id].irq_clear,
		LPAIF_IRQ_ALL(bus->device_id));
	clrbits_le32(&lpass_reg->bit_cbcr[bus->device_id].ibit_cbcr, ENABLE);

	write32(&lpass_reg->dma_rd_reg[bus->device_id].rddma_ctl, DISABLE);

	free(buffer);

	return ret;
}

LpassI2s *new_lpass_i2s(uint32_t sample_rate, uint32_t channels,
				uint32_t bitwidth, uint8_t device_id,
				uintptr_t base_addr)
{
	LpassI2s *bus = xzalloc(sizeof(*bus));

	bus->ops.send = &lpass_i2s_send;
	bus->lpass_regs = (LpassReg *)base_addr;
	bus->device_id = device_id;
	bus->bclk_rate = channels * bitwidth * sample_rate;

	return bus;
}
