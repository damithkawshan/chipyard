// See LICENSE.Sifive for license details.

// How to build and test SD boot on VCU118:
/*
# --- CONFIGURATION ---
# SD_SLOW_DEBUG and SD_TEST_PAYLOAD are hardcoded as #define below.
# Toggle them by commenting/uncommenting the #define lines.
# EXTRA_CFLAGS does NOT work — the Scala build ignores it.

# --- OPTION A: Test payload (quick debug, ~64KB) ---
# Enable: #define SD_SLOW_DEBUG  +  #define SD_TEST_PAYLOAD
#
# Build test payload binary:
make -C fpga/src/main/resources/vcu118/sd_test_payload
#
# Prep SD card (replace /dev/sdX with your device):
sudo sgdisk -Z /dev/sdX
sudo sgdisk -n 1:34:+30M -t 1:0700 /dev/sdX
sudo dd if=fpga/src/main/resources/vcu118/sd_test_payload/build/test_payload.bin \
  of=/dev/sdX1 bs=4M conv=fsync
sync

# --- OPTION B: Linux boot (FireMarshal, ~30MB) ---
# Enable: #define SD_SLOW_DEBUG  +  comment out #define SD_TEST_PAYLOAD
#
# Build & write FireMarshal image:
# (use fpga/scripts/writeSDPayload.sh or manual dd to partition at sector 34)

# --- BUILD BITSTREAM ---
# After changing any #define, rebuild the bitstream:
source env.sh
rm -f fpga/generated-src/chipyard.fpga.vcu118.VCU118FPGATestHarness.BaselineVCU118SDBootConfig/chipyard.fpga.vcu118.VCU118FPGATestHarness.BaselineVCU118SDBootConfig.fir
cd fpga && make SUB_PROJECT=vcu118 CONFIG=BaselineVCU118SDBootConfig bitstream
# Note: deleting the .fir forces Chisel to re-elaborate and re-embed sdboot.bin
*/

#include <stdint.h>

#include <platform.h>

#include "common.h"

#define DEBUG
#include "kprintf.h"

// PROPOSED FIX : DAMITH LOWER SD CARD
// Uncomment these for debugging, comment out for production
#define SD_SLOW_DEBUG       // Keep 400 kHz init clock for CMD18 (isolates clock issues)
//#define SD_TEST_PAYLOAD     // Read only 64KiB (for quick debug with test_payload.bin)

// Total payload in B
// PROPOSED FIX : DAMITH LOWER SD CARD
// Use SD_TEST_PAYLOAD to read only 64KiB (for quick debug with test_payload.bin)
// Use SD_SLOW_DEBUG to keep the 400 kHz init clock for CMD18 (isolates clock issues)
#ifdef SD_TEST_PAYLOAD
#define PAYLOAD_SIZE_B (64 << 10) // 64KiB for test
#else
#define PAYLOAD_SIZE_B (30 << 20) // default: 30MiB
#endif
// A sector is 512 bytes, so (1 << 11) * 512B = 1 MiB
#define SECTOR_SIZE_B 512
// Payload size in # of sectors
#define PAYLOAD_SIZE (PAYLOAD_SIZE_B / SECTOR_SIZE_B)

// The sector at which the BBL partition starts
#define BBL_PARTITION_START_SECTOR 34

#ifndef TL_CLK
#error Must define TL_CLK
#endif

#define F_CLK 		(TL_CLK)

// PROPOSED FIX : DAMITH LOWER SD CARD
// SPI SCLK frequency for data transfer, in kHz
// Original was 25000 (25 MHz) which caused CMD18 timeout on VCU118.
// Lowered to 5000 (5 MHz) to match working Genesys2 configuration.
#define SPI_CLK 	5000

// SPI clock divisor value
// @see https://ucb-bar.gitbook.io/baremetal-ide/baremetal-ide/using-peripheral-devices/sifive-ips/serial-peripheral-interface-spi
#define SPI_DIV 	(((F_CLK * 1000) / SPI_CLK) / 2 - 1)

// PROPOSED FIX : DAMITH LOWER SD CARD
// SD specification requires ≤400 kHz during identification/init phase (CMD0-CMD58).
// Original code used SPI_DIV (25 MHz) for init, causing CMD0 timeout.
#define SPI_INIT_CLK	400
#define SPI_INIT_DIV	(((F_CLK * 1000) / SPI_INIT_CLK) / 2 - 1)

static volatile uint32_t * const spi = (void *)(SPI_CTRL_ADDR);

static inline uint8_t spi_xfer(uint8_t d)
{
	int32_t r;

	REG32(spi, SPI_REG_TXFIFO) = d;
	do {
		r = REG32(spi, SPI_REG_RXFIFO);
	} while (r < 0);
	return r;
}

static inline uint8_t sd_dummy(void)
{
	return spi_xfer(0xFF);
}

static uint8_t sd_cmd(uint8_t cmd, uint32_t arg, uint8_t crc)
{
	unsigned long n;
	uint8_t r;

	REG32(spi, SPI_REG_CSMODE) = SPI_CSMODE_HOLD;
	sd_dummy();
	spi_xfer(cmd);
	spi_xfer(arg >> 24);
	spi_xfer(arg >> 16);
	spi_xfer(arg >> 8);
	spi_xfer(arg);
	spi_xfer(crc);

	n = 1000;
	do {
		r = sd_dummy();
		if (!(r & 0x80)) {
//			dprintf("sd:cmd: %hx\r\n", r);
			goto done;
		}
	} while (--n > 0);
	kputs("sd_cmd damith: timeout");
done:
	return r;
}

static inline void sd_cmd_end(void)
{
	sd_dummy();
	REG32(spi, SPI_REG_CSMODE) = SPI_CSMODE_AUTO;
}


static void sd_poweron(void)
{
	long i;
	// PROPOSED FIX : DAMITH LOWER SD CARD
	// Use ≤400 kHz during init (was: SPI_DIV = 25 MHz, which caused CMD0 timeout)
	REG32(spi, SPI_REG_SCKDIV) = SPI_INIT_DIV;
	REG32(spi, SPI_REG_CSMODE) = SPI_CSMODE_OFF;
	for (i = 10; i > 0; i--) {
		sd_dummy();
	}
	REG32(spi, SPI_REG_CSMODE) = SPI_CSMODE_AUTO;
}

static int sd_cmd0(void)
{
	int rc;
	dputs("CMD0");
	rc = (sd_cmd(0x40, 0, 0x95) != 0x01);
	sd_cmd_end();
	return rc;
}

static int sd_cmd8(void)
{
	int rc;
	dputs("CMD8");
	rc = (sd_cmd(0x48, 0x000001AA, 0x87) != 0x01);
	sd_dummy(); /* command version; reserved */
	sd_dummy(); /* reserved */
	rc |= ((sd_dummy() & 0xF) != 0x1); /* voltage */
	rc |= (sd_dummy() != 0xAA); /* check pattern */
	sd_cmd_end();
	return rc;
}

static void sd_cmd55(void)
{
	sd_cmd(0x77, 0, 0x65);
	sd_cmd_end();
}

static int sd_acmd41(void)
{
	uint8_t r;
	dputs("ACMD41");
	do {
		sd_cmd55();
		r = sd_cmd(0x69, 0x40000000, 0x77); /* HCS = 1 */
	} while (r == 0x01);
	return (r != 0x00);
}

static int sd_cmd58(void)
{
	int rc;
	dputs("CMD58");
	rc = (sd_cmd(0x7A, 0, 0xFD) != 0x00);
	rc |= ((sd_dummy() & 0x80) != 0x80); /* Power up status */
	sd_dummy();
	sd_dummy();
	sd_dummy();
	sd_cmd_end();
	return rc;
}

static int sd_cmd16(void)
{
	int rc;
	dputs("CMD16");
	rc = (sd_cmd(0x50, 0x200, 0x15) != 0x00);
	sd_cmd_end();
	return rc;
}

static uint16_t crc16_round(uint16_t crc, uint8_t data) {
	crc = (uint8_t)(crc >> 8) | (crc << 8);
	crc ^= data;
	crc ^= (uint8_t)(crc >> 4) & 0xf;
	crc ^= crc << 12;
	crc ^= (crc & 0xff) << 5;
	return crc;
}

#define SPIN_SHIFT	6
#define SPIN_UPDATE(i)	(!((i) & ((1 << SPIN_SHIFT)-1)))
#define SPIN_INDEX(i)	(((i) >> SPIN_SHIFT) & 0x3)

static const char spinner[] = { '-', '/', '|', '\\' };

static int copy(void)
{
	volatile uint8_t *p = (void *)(PAYLOAD_DEST);
	long i = PAYLOAD_SIZE;
	int rc = 0;

	dputs("CMD18");

	kprintf("LOADING 0x%x B PAYLOAD\r\n", PAYLOAD_SIZE_B);
	kprintf("LOADING  ");

	// PROPOSED FIX : DAMITH LOWER SD CARD
	// Clock transition for data transfer.
	// SD_SLOW_DEBUG: keep init clock (~400 kHz) to isolate speed issues.
	// Normal mode: switch to SPI_DIV (5 MHz) with settling clocks.
#ifdef SD_SLOW_DEBUG
	kputs("SLOW_DEBUG: keeping init clock");
	// Stay at SPI_INIT_DIV — no clock change
#else
	REG32(spi, SPI_REG_SCKDIV) = SPI_DIV;
#endif
	// Send dummy clocks after clock change to let card settle
	{
		long j;
		REG32(spi, SPI_REG_CSMODE) = SPI_CSMODE_OFF;
		for (j = 10; j > 0; j--) {
			sd_dummy();
		}
		REG32(spi, SPI_REG_CSMODE) = SPI_CSMODE_AUTO;
	}

	if (sd_cmd(0x52, BBL_PARTITION_START_SECTOR, 0xE1) != 0x00) {
		sd_cmd_end();
		return 1;
	}
	do {
		uint16_t crc, crc_exp;
		long n;

		crc = 0;
		n = SECTOR_SIZE_B;
		while (sd_dummy() != 0xFE);
		do {
			uint8_t x = sd_dummy();
			*p++ = x;
			crc = crc16_round(crc, x);
		} while (--n > 0);

		crc_exp = ((uint16_t)sd_dummy() << 8);
		crc_exp |= sd_dummy();

		if (crc != crc_exp) {
			kputs("\b- CRC mismatch ");
			rc = 1;
			break;
		}

		if (SPIN_UPDATE(i)) {
			kputc('\b');
			kputc(spinner[SPIN_INDEX(i)]);
		}
	} while (--i > 0);
	sd_cmd_end();

	sd_cmd(0x4C, 0, 0x01);
	sd_cmd_end();
	kputs("\b ");
	return rc;
}

int main(void)
{
	REG32(uart, UART_REG_TXCTRL) = UART_TXEN;

	kputs("INIT");
	sd_poweron();
	if (sd_cmd0() ||
	    sd_cmd8() ||
	    sd_acmd41() ||
	    sd_cmd58() ||
	    sd_cmd16() ||
	    copy()) {
		kputs("ERROR");
		return 1;
	}

	kputs("BOOT");

	__asm__ __volatile__ ("fence.i" : : : "memory");

	return 0;
}