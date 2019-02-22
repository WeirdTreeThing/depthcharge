/*
 * Copyright (C) 2019, The Linux Foundation.  All rights reserved.
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

#ifndef __DRIVERS_STORAGE_SDHCI_MSM_H__
#define __DRIVERS_STORAGE_SDHCI_MSM_H__

#include "drivers/storage/sdhci.h"
#include "drivers/gpio/gpio.h"

/* SDM specific defines */
#define SDC1_TLMM_CONFIG	0x9FE4
#define SDC2_TLMM_CONFIG	0x1FE4

/* SDHC specific defines */
#define SDCC_HC_VENDOR_SPECIFIC_FUNC1	0x20C
#define VENDOR_SPEC_FUN1_POR_VAL	0xA0C
#define HC_IO_PAD_PWR_SWITCH_EN		(1 << 15)
#define HC_IO_PAD_PWR_SWITCH		(1 << 16)
#define HC_SELECT_IN_EN			(1 << 18)
#define HC_SELECT_IN_MASK		(7 << 19)
#define SDCC_HC_VENDOR_SPECIFIC_FUNC3	0x250
#define VENDOR_SPEC_FUN3_POR_VAL	0x02226040
#define SDCC_HC_VENDOR_SPECIFIC_CAPABILITIES0	0x21C

SdhciHost *new_sdhci_msm_host(void *ioaddr, int platform_info, int clock_max,
			      void *tlmmAddr, GpioOps *cd_gpio);

#endif /* __DRIVERS_STORAGE_SDHCI_MSM_H__ */
