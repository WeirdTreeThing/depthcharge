// SPDX-License-Identifier: GPL-2.0

#include "board/guybrush/include/variant.h"
#include "drivers/sound/rt5682.h"

unsigned int variant_get_cr50_irq_gpio(void)
{
	return CR50_INT_3;
}

SoundRouteComponent *variant_get_audio_codec(I2cOps *i2c, uint8_t chip,
					     uint32_t mclk, uint32_t lrclk)
{
	rt5682Codec *rt5682 = new_rt5682_codec(i2c, chip, mclk, lrclk);

	return &rt5682->component;
}
