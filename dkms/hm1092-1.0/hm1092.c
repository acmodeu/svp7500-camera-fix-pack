// SPDX-License-Identifier: GPL-2.0-only
/*
 * Himax HM1092 IR camera sensor driver
 *
 * 1280x720 NIR (near-infrared) CMOS image sensor for face authentication.
 * 1-lane MIPI CSI-2, 10-bit mono output, 30fps.
 *
 * Register layout inferred from the HM11B1/HM2170 Himax sensor family
 * (same 16-bit address, 8-bit data architecture).
 *
 * Copyright (C) 2026 Contributors
 */

#include <linux/acpi.h>
#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/leds.h>
#include <linux/module.h>
#include <linux/pm_runtime.h>
#include <linux/regulator/consumer.h>
#include <linux/workqueue.h>

#include <media/v4l2-ctrls.h>
#include <media/v4l2-device.h>
#include <media/v4l2-fwnode.h>
#include <media/v4l2-subdev.h>

/*
 * Exported by intel_cvs. Fires HOST_SET_MIPI_CONFIG (0x0830) with the verbatim
 * Windows-trace IR payload, configuring the SVP7500 bridge for port-2 (IR)
 * forwarding. We call this from hm1092_set_stream(1) AFTER MODE_SELECT=0x01
 * so the bridge sees an actively-clocking port 2 input when it processes the
 * config (Windows-Hello ordering, ~182ms gap in the trace).
 *
 * Weak ref so hm1092 still loads if intel_cvs is unavailable; we just won't be
 * able to enable port-2 forwarding from the sensor side.
 */
extern int __weak cvs_send_mipi_ir_config(void);
extern int __weak cvs_send_mipi_rgb_config(void);

/*
 * Diagnostic module parameters — runtime-tunable for experiments without
 * needing a DKMS rebuild. Adjust via:
 *   echo 200 | sudo tee /sys/module/hm1092/parameters/mipi_ir_delay_ms
 */
static unsigned int mipi_ir_delay_ms;
module_param(mipi_ir_delay_ms, uint, 0644);
MODULE_PARM_DESC(mipi_ir_delay_ms,
		 "ms to sleep between sensor MODE_SELECT=0x01 and bridge mipi-ir config (Windows trace has ~182ms here)");

static bool send_bridge_config = true;
module_param(send_bridge_config, bool, 0644);
MODULE_PARM_DESC(send_bridge_config,
		 "Send intel_cvs HOST_SET_MIPI_CONFIG during stream-on (disable for externally injected transaction tests)");

static bool external_stream_control;
module_param(external_stream_control, bool, 0644);
MODULE_PARM_DESC(external_stream_control,
		 "Arm the IPU pipeline without programming HM1092; used while replaying the captured Windows dual-sensor sequence externally");

/*
 * Windows arms the sensor PART-WAY THROUGH the init table (at entry 198 of 238)
 * and streams the trailing 40 writes (its AE groups) while already streaming.
 * We historically wrote all 238 then armed. Terminal register state is identical
 * (verified by i2c readback); only the sequence differs. Set to 198 to replay
 * Windows' order exactly; 0 keeps the legacy behaviour.
 */
static unsigned int arm_at_entry;
module_param(arm_at_entry, uint, 0644);
MODULE_PARM_DESC(arm_at_entry,
		 "Arm (MODE_SELECT=0x01) after writing this many init entries, then write the rest while streaming (0=write all then arm; 198=Windows-faithful)");

static bool dump_regs_on_stream = false;
module_param(dump_regs_on_stream, bool, 0644);
MODULE_PARM_DESC(dump_regs_on_stream,
		 "If true, log values of 0x4b20 and 0x0101 in hm1092_set_stream(1) - lets us check whether the values we blind-write to chip-specific calibration regs match what the chip actually wants");

static unsigned int ae_kick_period_ms;
module_param(ae_kick_period_ms, uint, 0644);
MODULE_PARM_DESC(ae_kick_period_ms,
		 "If non-zero, hm1092 kicks 0x0104=0x01 to the sensor every N ms while streaming (Windows trace does this every ~132ms - hypothesis is bridge needs periodic refresh to keep MIPI tunnel hot)");

/*
 * HYPOTHESIS #11 (2026-06-11): per-session dvdd GPIO WRITE is the bridge's
 * port-2 arming trigger.
 *
 * dvdd is not a SoC GPIO — it's bridge VGPO pin1 (gpiochip5/INTC10E2), a
 * *virtual* GPIO terminated inside the Synaptics SVP7500 firmware. The
 * tverhaeghe USBPcaps show Windows writes pin1=1 as the FIRST op of EVERY
 * Hello session (t+0, sensor I2C init follows 1.6ms later) and pin1=0 at
 * teardown — i.e. the bridge firmware observes a dvdd write *event* at the
 * start of each IR session. Linux asserts dvdd once at probe (boot) and
 * holds it forever, so at stream time the bridge never sees the event.
 * If bridge fw uses that write to arm its port-2 MIPI forwarding state
 * machine (cf. usbbridge.sys "1_BRIDGE_STATE_TRIGGER_CTX"), holding the
 * *level* satisfies the sensor's power rail but never trips the trigger.
 *
 * If non-zero: at s_stream(1), BEFORE sensor init, cycle the dvdd regulator
 * off for N ms then back on (generating the same USBIO GPIO-write wire
 * commands Windows sends: pin1=0, pin1=1), wait 3ms (Windows: 1.6ms from
 * dvdd=1 to first sensor I2C), then proceed with the normal init flow.
 */
static unsigned int dvdd_cycle_ms;
module_param(dvdd_cycle_ms, uint, 0644);
MODULE_PARM_DESC(dvdd_cycle_ms,
		 "If non-zero, cycle dvdd (bridge VGPO pin1) off for N ms at stream start to replay Windows' per-session GPIO write event (0=disabled)");

/* Chip identification */
#define HM1092_CHIP_ID			0x1091	/* Silicon reports 0x1091, not 0x1092 */
#define HM1092_REG_CHIP_ID		0x0000	/* 16-bit, big-endian */

/* Mode control */
#define HM1092_REG_MODE_SELECT		0x0100
#define HM1092_MODE_STANDBY		0x00
#define HM1092_MODE_STREAMING		0x01

/* Command update — Windows commits each runtime AE group with 0x01 */
#define HM1092_REG_COMMAND_UPDATE	0x0104

/* Exposure */
#define HM1092_REG_EXPOSURE		0x0202	/* 16-bit coarse integration time */
#define HM1092_EXPOSURE_MIN		2
#define HM1092_EXPOSURE_MAX		720
#define HM1092_EXPOSURE_DEFAULT		256
#define HM1092_EXPOSURE_STEP		1

/* Analog gain */
#define HM1092_REG_ANALOG_GAIN		0x0205	/* 8-bit */
#define HM1092_AGAIN_MIN		0
#define HM1092_AGAIN_MAX		0xff
#define HM1092_AGAIN_DEFAULT		0x10
#define HM1092_AGAIN_STEP		1

/* Digital gain */
#define HM1092_REG_DIGITAL_GAIN		0x020e	/* 16-bit; Windows writes 0x020e/0x020f */
#define HM1092_DGAIN_MIN		0x0100
#define HM1092_DGAIN_MAX		0x0fff
#define HM1092_DGAIN_DEFAULT		0x0100
#define HM1092_DGAIN_STEP		1

/* Test pattern */
#define HM1092_REG_TEST_PATTERN		0x0601
#define HM1092_TEST_PATTERN_OFF		0x00
#define HM1092_TEST_PATTERN_ON		0x01

/* Frame timing */
#define HM1092_REG_VTS			0x0340	/* 16-bit, vertical total size */
#define HM1092_REG_HTS			0x0342	/* 16-bit, horizontal total size */

/*
 * Fixed output format — 648×368 GR1P (10-bit packed mono w/ overscan crop).
 *
 * Why 648×368 and not 1280×720?  Cracked open Dell's v81 Vision driver
 * (Intel 2D Imaging/USB IO/Vision Driver YMY0G_WIN64_81.26100.0.13_A01)
 * and parsed every graph_settings_hm1092_*_PTL.bin file it ships:
 *
 *   22 production module variants (BBG/CBG/CJF — Bison, Chicony, Cammsys):
 *     ALL of them stream HM1092 at GR1P 648×368, 30 fps.
 *     ZERO of them advertise 1280×720 as a streaming config.
 *
 * Only the dev/reference board (1BD8221) lists higher resolutions, which
 * we believe map to the Windows-Hello full-frame path — not the always-on
 * CV stream our hardware actually uses.  Production firmware ONLY validates
 * the 648×368 GR1P pipeline through the bridge's port-2 secure handshake.
 *
 * Our 240-register init sequence below is byte-identical to Windows USBPcap
 * (intel/vision-drivers#37, 2026-05-12).  Since Windows streams 648×368,
 * those registers ALREADY program the sensor for 648×368 output — we were
 * just lying to V4L2/IPU7 about what geometry comes out, so the receiver
 * was throwing away mismatched-size frames at the CSI-2 boundary.
 *
 * 648 = 640 + 8 horizontal overscan past 2x2-binned 1280.
 * 368 = 360 + 8 vertical overscan past 2x2-binned 720.
 */
/* full pixel array; the exposed mode is the 2x2 binned window + overscan */
#define HM1092_NATIVE_WIDTH		1280
#define HM1092_NATIVE_HEIGHT		720
#define HM1092_WIDTH			648
#define HM1092_HEIGHT			368
/*
 * The sensor outputs 10-bit mono, but IPU7 ISYS only accepts Bayer formats.
 * Report as SGRBG10 — the mono IR data will be captured identically
 * (single-channel data interpreted as one Bayer color, which is fine).
 * "GR1P" in Dell's graph_settings file = SGRBG10 packed (Intel naming).
 */
#define HM1092_MBUS_CODE		MEDIA_BUS_FMT_SGRBG10_1X10

/* MIPI CSI-2 */
#define HM1092_LANES			1
/* 19.2 MHz MCLK * 94 (PLL mult 0x5E) / 5 (PLL div 0x0A) = 360.96 MHz */
#define HM1092_LINK_FREQ_384MHZ		360960000ULL
/*
 * Corrected value. hm1092.sys's mode descriptor declares 360,960,000 as the
 * per-lane BIT RATE (1620*740*30*10bpp for 648x368@30, 1 lane RAW10) and
 * pixel_rate 36,000,000. V4L2_CID_LINK_FREQ is the DDR clock = bitrate/2.
 * Publishing the bit rate made isys program the D-PHY at ~721 Mbps, 2x the
 * sensor's real line rate -- consistent with the clock lane going active while
 * the data lane never validates a packet.
 */
#define HM1092_LINK_FREQ_180MHZ		180480000ULL
/*
 * 2026-05-13 NOTE: a brief experiment changed these to LANES=2 +
 * LINK_FREQ=1497600000 based on Windows USBPcap decode of the bridge's
 * 0x830 payload (which announces 2 lanes / 1497.6 MHz on the bridge→IPU7
 * link).  Combined with a parallel ipu-bridge override of sensor->lanes,
 * this caused graphics artifacts and a hard system freeze on PTL — the
 * IPU7 firmware doesn't fail-safe on lane/frequency mismatches and the
 * resulting bad DMA appears to corrupt IOMMU pages shared with the Xe
 * GPU.  Reverted to the original safe values; lane/freq change requires
 * Intel-side coordination (filed via vision-drivers thread).
 */

/*
 * Minimal init sequence — just enough to configure the sensor for streaming.
 * The PLL, timing, and output format registers are based on the HM11B1 family.
 * If these don't work, we'll need to capture the actual init from Windows.
 */
struct hm1092_reg {
	u16 addr;
	u8 val;
};

/*
 * Init sequence extracted from Dell Windows driver hm1092.sys
 * (Intel-2D-Imaging-USB-IO-Vision-Driver-for-Camera, version 81.26100.0.13)
 * Binary at offset 0x26B34 in .rdata section, 16-byte entries.
 */
static const struct hm1092_reg hm1092_init_regs[] = {
	/*
	 * COMPLETE Windows sensor write sequence from tverhaeghe's
	 * windows_hello_unlock USBPcap capture (intel/vision-drivers#37,
	 * 2026-05-12). 240 register writes in EXACT Windows order.
	 *
	 * NOTE (2026-07-09): the capture is a WHOLE Hello session — init,
	 * a single stream-on, the runtime AE loop, AND the session teardown
	 * (final 0x0100=0x00). Replaying it verbatim, then re-streaming in
	 * hm1092_set_stream(1), made the sensor arm/disarm/re-arm — a
	 * double-arm no real Hello session performs. The mid-table stream-on
	 * and the teardown standby have been removed (see inline comments);
	 * the sensor is armed exactly ONCE, terminally, in set_stream(1),
	 * matching the Windows single-arm structure.
	 */
	{ 0x0100, 0x00 },
	{ 0x0103, 0x00 },
	{ 0x0000, 0x00 },
	{ 0x0101, 0x00 },
	{ 0x0202, 0x02 },
	{ 0x0203, 0xe5 },
	{ 0x0307, 0x00 },
	{ 0x0309, 0x01 },
	{ 0x030a, 0x05 },
	{ 0x030d, 0x0a },
	{ 0x030f, 0x5e },
	{ 0x0310, 0x00 },
	{ 0x0340, 0x03 },
	{ 0x0341, 0x1e },
	{ 0x0342, 0x05 },
	{ 0x0343, 0xe4 },
	{ 0x0350, 0x53 },
	{ 0x0387, 0x01 },
	{ 0x3110, 0x02 },
	{ 0x3735, 0xe2 },
	{ 0x3704, 0x04 },
	{ 0x4001, 0x00 },
	{ 0x4002, 0x2b },
	{ 0x4024, 0x40 },
	{ 0x4131, 0x01 },
	{ 0x4132, 0x20 },
	{ 0x4265, 0x02 },
	{ 0x4b04, 0x01 },
	{ 0x4b0e, 0x0e },
	{ 0x4b18, 0x00 },
	{ 0x4b20, 0x9e },
	{ 0x4b31, 0x06 },
	{ 0x4b3b, 0x02 },
	{ 0x4b3e, 0x00 },
	{ 0x4b44, 0x0c },
	{ 0x4b45, 0x01 },
	{ 0x4b47, 0x00 },
	{ 0x5004, 0x40 },
	{ 0x5005, 0x28 },
	{ 0x5006, 0x40 },
	{ 0x5007, 0x28 },
	{ 0x5010, 0x20 },
	{ 0x5011, 0x00 },
	{ 0x5013, 0x03 },
	{ 0x5015, 0xb3 },
	{ 0x501d, 0x4c },
	{ 0x5098, 0x00 },
	{ 0x5099, 0x11 },
	{ 0x509b, 0x03 },
	{ 0x50a0, 0x30 },
	{ 0x50a2, 0x0b },
	{ 0x50a6, 0x00 },
	{ 0x50a7, 0x00 },
	{ 0x50aa, 0x22 },
	{ 0x50ab, 0x07 },
	{ 0x50ac, 0x24 },
	{ 0x50ad, 0x07 },
	{ 0x50ae, 0x20 },
	{ 0x50af, 0x40 },
	{ 0x50b3, 0x04 },
	{ 0x50b4, 0x00 },
	{ 0x50b7, 0x00 },
	{ 0x50b8, 0x70 },
	{ 0x50b9, 0xff },
	{ 0x50ba, 0xff },
	{ 0x50bb, 0x14 },
	{ 0x50cb, 0x21 },
	{ 0x50d5, 0xe0 },
	{ 0x50d7, 0x12 },
	{ 0x50dd, 0x00 },
	{ 0x50e8, 0x00 },
	{ 0x50ea, 0x74 },
	{ 0x50fa, 0x02 },
	{ 0x5100, 0x03 },
	{ 0x5101, 0x13 },
	{ 0x5102, 0x23 },
	{ 0x5103, 0x33 },
	{ 0x5104, 0x43 },
	{ 0x5105, 0x42 },
	{ 0x5106, 0x40 },
	{ 0x5118, 0x00 },
	{ 0x5119, 0x00 },
	{ 0x511a, 0x00 },
	{ 0x511b, 0x00 },
	{ 0x511c, 0x00 },
	{ 0x511d, 0x00 },
	{ 0x511e, 0x00 },
	{ 0x5130, 0x13 },
	{ 0x5131, 0x23 },
	{ 0x5132, 0x33 },
	{ 0x5133, 0x43 },
	{ 0x5134, 0x42 },
	{ 0x5135, 0x40 },
	{ 0x5136, 0x40 },
	{ 0x5148, 0x01 },
	{ 0x5149, 0x01 },
	{ 0x514a, 0x01 },
	{ 0x514b, 0x01 },
	{ 0x514c, 0x01 },
	{ 0x514d, 0x01 },
	{ 0x514e, 0x01 },
	{ 0x51c0, 0x00 },
	{ 0x51c1, 0x81 },
	{ 0x51c2, 0xec },
	{ 0x51c3, 0x00 },
	{ 0x51c4, 0x55 },
	{ 0x51c5, 0x44 },
	{ 0x51c6, 0x00 },
	{ 0x51c7, 0x81 },
	{ 0x51c8, 0xec },
	{ 0x51c9, 0x00 },
	{ 0x51ca, 0x55 },
	{ 0x51cb, 0x24 },
	{ 0x51cc, 0x00 },
	{ 0x51cd, 0x81 },
	{ 0x51ce, 0xec },
	{ 0x51cf, 0x00 },
	{ 0x51d0, 0x54 },
	{ 0x51d1, 0x24 },
	{ 0x51d2, 0x00 },
	{ 0x51d3, 0x81 },
	{ 0x51d4, 0xec },
	{ 0x51d5, 0x00 },
	{ 0x51d6, 0x53 },
	{ 0x51d7, 0x14 },
	{ 0x51d8, 0x00 },
	{ 0x51d9, 0x81 },
	{ 0x51da, 0xec },
	{ 0x51db, 0x00 },
	{ 0x51dc, 0x53 },
	{ 0x51dd, 0x14 },
	{ 0x51e0, 0x09 },
	{ 0x51e1, 0x03 },
	{ 0x51e2, 0x04 },
	{ 0x51e3, 0x03 },
	{ 0x51e4, 0x08 },
	{ 0x51e5, 0x07 },
	{ 0x51e6, 0x08 },
	{ 0x51e7, 0x07 },
	{ 0x51e8, 0x04 },
	{ 0x51e9, 0x46 },
	{ 0x51ea, 0x43 },
	{ 0x51eb, 0x62 },
	{ 0x51ec, 0x61 },
	{ 0x51ed, 0x00 },
	{ 0x51ee, 0x00 },
	{ 0x5200, 0x60 },
	{ 0x5201, 0x80 },
	{ 0x5202, 0x00 },
	{ 0x5203, 0x01 },
	{ 0x5206, 0x80 },
	{ 0x5208, 0x0b },
	{ 0x5209, 0x0c },
	{ 0x520c, 0x15 },
	{ 0x520d, 0x40 },
	{ 0x5214, 0x28 },
	{ 0x5215, 0x04 },
	{ 0x5216, 0x02 },
	{ 0x5217, 0x01 },
	{ 0x5218, 0x07 },
	{ 0x521e, 0x01 },
	{ 0x5282, 0xff },
	{ 0x5283, 0x03 },
	{ 0x0202, 0x01 },
	{ 0x0203, 0x68 },
	{ 0x0340, 0x02 },
	{ 0x0341, 0xe4 },
	{ 0x0342, 0x06 },
	{ 0x0343, 0x54 },
	{ 0x0344, 0x00 },
	{ 0x0345, 0x00 },
	{ 0x0346, 0x00 },
	{ 0x0347, 0x00 },
	{ 0x0348, 0x05 },
	{ 0x0349, 0x0d },
	{ 0x034a, 0x02 },
	{ 0x034b, 0xdd },
	{ 0x034c, 0x02 },
	{ 0x034d, 0x88 },
	{ 0x034e, 0x01 },
	{ 0x034f, 0x70 },
	{ 0x0383, 0x00 },
	{ 0x0387, 0x10 },
	{ 0x0390, 0x03 },
	{ 0x4800, 0xac },
	{ 0x0104, 0x01 },
	{ 0x0104, 0x00 },
	{ 0x4801, 0xae },
	{ 0x4b20, 0x9e },
	{ 0x0101, 0x03 },
	{ 0x0340, 0x02 },
	{ 0x0341, 0xe5 },
	{ 0x0202, 0x00 },
	{ 0x0203, 0xae },
	{ 0x0205, 0x00 },
	{ 0x020e, 0x01 },
	{ 0x020f, 0x00 },
	{ 0x0104, 0x01 },
	/*
	 * REMOVED 2026-07-09 (single-arm fix): this mid-table stream-on
	 * (0x0100=0x01), combined with the teardown standby (0x0100=0x00) at
	 * the end of this table, made the sensor double-arm: ON -> [AE frames]
	 * -> OFF -> (ctrl stomps) -> ON (in hm1092_set_stream). The captured
	 * Windows Hello session streams on exactly ONCE and the trailing 0x00
	 * was Windows' *session teardown*, not part of stream setup. The
	 * SVP7500 bridge appears to latch port-2 MIPI forwarding on the FIRST
	 * clock edge; our teardown de-armed it and the re-enable was an edge it
	 * no longer watched. Sensor now streams once, terminally, in
	 * hm1092_set_stream(1). The following AE-loop writes are left in place
	 * (harmless while in standby; set converged exposure before stream-on).
	 */
	{ 0x0340, 0x02 },
	{ 0x0341, 0xe5 },
	{ 0x0202, 0x00 },
	{ 0x0203, 0xa1 },
	{ 0x0205, 0x00 },
	{ 0x020e, 0x01 },
	{ 0x020f, 0x00 },
	{ 0x0104, 0x01 },
	{ 0x0340, 0x02 },
	{ 0x0341, 0xe5 },
	{ 0x0202, 0x00 },
	{ 0x0203, 0x85 },
	{ 0x0205, 0x00 },
	{ 0x020e, 0x01 },
	{ 0x020f, 0x00 },
	{ 0x0104, 0x01 },
	{ 0x0340, 0x02 },
	{ 0x0341, 0xe5 },
	{ 0x0202, 0x00 },
	{ 0x0203, 0x80 },
	{ 0x0205, 0x00 },
	{ 0x020e, 0x01 },
	{ 0x020f, 0x00 },
	{ 0x0104, 0x01 },
	{ 0x0340, 0x02 },
	{ 0x0341, 0xe5 },
	{ 0x0202, 0x00 },
	{ 0x0203, 0x91 },
	{ 0x0205, 0x00 },
	{ 0x020e, 0x01 },
	{ 0x020f, 0x00 },
	{ 0x0104, 0x01 },
	{ 0x0340, 0x02 },
	{ 0x0341, 0xe5 },
	{ 0x0202, 0x00 },
	{ 0x0203, 0xb4 },
	{ 0x0205, 0x00 },
	{ 0x020e, 0x01 },
	{ 0x020f, 0x00 },
	{ 0x0104, 0x01 },
	/* REMOVED 2026-07-09 (single-arm fix): Windows session-teardown
	 * standby — see the block comment above. Table now leaves the sensor
	 * in standby (from the 0x0100=0x00 at the top), ready for a single
	 * terminal stream-on in hm1092_set_stream(1). */
};

struct hm1092 {
	struct v4l2_subdev sd;
	struct media_pad pad;
	struct v4l2_ctrl_handler ctrl_handler;

	struct v4l2_ctrl *exposure;
	struct v4l2_ctrl *analogue_gain;
	struct v4l2_ctrl *digital_gain;
	struct v4l2_ctrl *test_pattern;
	struct v4l2_ctrl *link_freq;
	struct v4l2_ctrl *pixel_rate;
	struct v4l2_ctrl *hblank;
	struct v4l2_ctrl *vblank;

	/* Power supplies from INT3472 */
	struct regulator *dvdd;
	struct regulator *avdd;
	struct regulator *dovdd;
	bool dvdd_enabled;
	bool avdd_enabled;
	bool dovdd_enabled;

	/* Reference clock from INT3472 GPIO clock */
	struct clk *extclk;
	bool extclk_enabled;
	bool stream_clock_enabled;

	/*
	 * IR flood illuminator. int3472 maps a type 0x02 (STROBE) pin with
	 * con_id "ir_flood", and for that type it does NOT publish a GPIO --
	 * skl_int3472_register_led() consumes the descriptor and exposes a LED
	 * classdev plus a led_add_lookup() keyed on the sensor's device name.
	 * So on this machine the gpiod path below never resolves ("ir_led=none")
	 * and the LED one does. Keep both: some firmwares may still hand the pin
	 * over as a plain GPIO.
	 */
	struct gpio_desc *ir_led;
	struct led_classdev *ir_led_cdev;

	bool streaming;

	/*
	 * TEST 3: periodic AE-kick worker. Windows trace writes 0x0104=0x01
	 * to the IR sensor every ~132ms once streaming starts (group-hold
	 * trigger inside the auto-exposure loop). Hypothesis: bridge keeps
	 * port-2 MIPI tunnel hot only while this register sees activity.
	 */
	struct delayed_work ae_kick_work;
};

static inline struct hm1092 *to_hm1092(struct v4l2_subdev *sd)
{
	return container_of(sd, struct hm1092, sd);
}

/* --- I2C register access (16-bit addr, 8-bit data) --- */

static int hm1092_read_reg(struct i2c_client *client, u16 reg, u8 *val)
{
	u8 addr[2] = { reg >> 8, reg & 0xff };
	struct i2c_msg msgs[2] = {
		{ .addr = client->addr, .flags = 0,
		  .len = 2, .buf = addr },
		{ .addr = client->addr, .flags = I2C_M_RD,
		  .len = 1, .buf = val },
	};
	int ret;

	ret = i2c_transfer(client->adapter, msgs, 2);
	if (ret != 2) {
		dev_err(&client->dev, "read reg 0x%04x failed: %d\n", reg, ret);
		return ret < 0 ? ret : -EIO;
	}
	return 0;
}

/*
 * Drive the IR illuminator, whichever way the firmware exposed it. Called only
 * around streaming, so the emitter is never left lit while idle.
 */
static void hm1092_ir_led_set(struct hm1092 *hm, bool on)
{
	if (hm->ir_led_cdev)
		led_set_brightness(hm->ir_led_cdev, on ? 1 : 0);
	if (hm->ir_led)
		gpiod_set_value_cansleep(hm->ir_led, on ? 1 : 0);
}

static int hm1092_write_reg(struct i2c_client *client, u16 reg, u8 val)
{
	u8 buf[3] = { reg >> 8, reg & 0xff, val };
	struct i2c_msg msg = {
		.addr = client->addr, .flags = 0,
		.len = 3, .buf = buf,
	};
	int ret;

	ret = i2c_transfer(client->adapter, &msg, 1);
	if (ret != 1) {
		dev_err(&client->dev, "write reg 0x%04x=0x%02x failed: %d\n",
			reg, val, ret);
		return ret < 0 ? ret : -EIO;
	}
	return 0;
}

static int hm1092_read_reg16(struct i2c_client *client, u16 reg, u16 *val)
{
	u8 hi, lo;
	int ret;

	ret = hm1092_read_reg(client, reg, &hi);
	if (ret)
		return ret;
	ret = hm1092_read_reg(client, reg + 1, &lo);
	if (ret)
		return ret;
	*val = (hi << 8) | lo;
	return 0;
}

static int hm1092_write_reg16(struct i2c_client *client, u16 reg, u16 val)
{
	int ret;

	ret = hm1092_write_reg(client, reg, val >> 8);
	if (ret)
		return ret;
	return hm1092_write_reg(client, reg + 1, val & 0xff);
}

static int hm1092_write_reg_list(struct i2c_client *client,
				  const struct hm1092_reg *regs, int count)
{
	int i, ret;

	for (i = 0; i < count; i++) {
		ret = hm1092_write_reg(client, regs[i].addr, regs[i].val);
		if (ret)
			return ret;
	}
	return 0;
}

/* --- V4L2 subdev operations --- */

static int hm1092_set_ctrl(struct v4l2_ctrl *ctrl)
{
	struct hm1092 *hm = container_of(ctrl->handler, struct hm1092,
					  ctrl_handler);
	struct i2c_client *client = v4l2_get_subdevdata(&hm->sd);
	int ret = 0;

	if (!hm->streaming)
		return 0;

	switch (ctrl->id) {
	case V4L2_CID_EXPOSURE:
		ret = hm1092_write_reg16(client, HM1092_REG_EXPOSURE,
					  ctrl->val);
		break;
	case V4L2_CID_ANALOGUE_GAIN:
		ret = hm1092_write_reg(client, HM1092_REG_ANALOG_GAIN,
				       ctrl->val);
		break;
	case V4L2_CID_DIGITAL_GAIN:
		ret = hm1092_write_reg16(client, HM1092_REG_DIGITAL_GAIN,
					  ctrl->val);
		break;
	case V4L2_CID_TEST_PATTERN:
		ret = hm1092_write_reg(client, HM1092_REG_TEST_PATTERN,
				       ctrl->val ? (ctrl->val << 1) |
				       HM1092_TEST_PATTERN_ON :
				       HM1092_TEST_PATTERN_OFF);
		break;
	default:
		return 0;
	}

	if (ret)
		return ret;

	/* Match the captured HM1092 runtime control groups: data, then 0x0104=1. */
	return hm1092_write_reg(client, HM1092_REG_COMMAND_UPDATE, 0x01);
}

static const struct v4l2_ctrl_ops hm1092_ctrl_ops = {
	.s_ctrl = hm1092_set_ctrl,
};

/*
 * index 0 = corrected DDR clock (180.48 MHz -> ~361 Mbps, matches Windows)
 * index 1 = legacy value (360.96 MHz -> ~722 Mbps)  <-- DEFAULT, unchanged
 * Selectable at runtime; isys reads this control at stream-on to program the
 * D-PHY. Default is the legacy value because a bad rate can hard-freeze PTL.
 */
static const s64 hm1092_link_freqs[] = {
	HM1092_LINK_FREQ_180MHZ,
	HM1092_LINK_FREQ_384MHZ,
};

static const char * const hm1092_test_pattern_menu[] = {
	"Disabled",
	"Solid Color",
};

static int hm1092_init_controls(struct hm1092 *hm)
{
	struct v4l2_ctrl_handler *handler = &hm->ctrl_handler;
	int ret;

	ret = v4l2_ctrl_handler_init(handler, 8);
	if (ret)
		return ret;

	/*
	 * HBLANK and VBLANK — required by libcamera's CameraSensor.
	 * Values are estimates for 1280x720 @ 30fps with 384MHz link freq.
	 * pixel_rate = 384M * 2 (DDR) * 1 lane / 10 bits = 76.8 Mpixels/sec
	 * HTS = pixel_rate / (VTS * fps) → with VTS=800: HTS=3200
	 * hblank = HTS - width = 3200 - 1280 = 1920
	 * vblank = VTS - height = 800 - 720 = 80
	 */
	hm->hblank = v4l2_ctrl_new_std(handler, &hm1092_ctrl_ops,
				       V4L2_CID_HBLANK, 1920, 1920, 1, 1920);
	if (hm->hblank)
		hm->hblank->flags |= V4L2_CTRL_FLAG_READ_ONLY;

	hm->vblank = v4l2_ctrl_new_std(handler, &hm1092_ctrl_ops,
				       V4L2_CID_VBLANK, 80, 2000, 1, 80);

	/*
	 * NOT read-only: index 0 selects the corrected 180.48 MHz DDR clock so the
	 * 2x-rate hypothesis can be A/B tested without a rebuild. Default index 1
	 * keeps the historical value.
	 */
	hm->link_freq = v4l2_ctrl_new_int_menu(handler, &hm1092_ctrl_ops,
						V4L2_CID_LINK_FREQ,
						ARRAY_SIZE(hm1092_link_freqs) - 1,
						0, hm1092_link_freqs);

	/* pixel_rate = link_freq * 2 (DDR) * lanes / bpp */
	hm->pixel_rate = v4l2_ctrl_new_std(handler, &hm1092_ctrl_ops,
					    V4L2_CID_PIXEL_RATE, 0,
					    HM1092_LINK_FREQ_180MHZ * 2 * HM1092_LANES / 10,
					    1,
					    HM1092_LINK_FREQ_180MHZ * 2 * HM1092_LANES / 10);
	if (hm->pixel_rate)
		hm->pixel_rate->flags |= V4L2_CTRL_FLAG_READ_ONLY;

	hm->exposure = v4l2_ctrl_new_std(handler, &hm1092_ctrl_ops,
					  V4L2_CID_EXPOSURE,
					  HM1092_EXPOSURE_MIN,
					  HM1092_EXPOSURE_MAX,
					  HM1092_EXPOSURE_STEP,
					  HM1092_EXPOSURE_DEFAULT);

	hm->analogue_gain = v4l2_ctrl_new_std(handler, &hm1092_ctrl_ops,
					       V4L2_CID_ANALOGUE_GAIN,
					       HM1092_AGAIN_MIN,
					       HM1092_AGAIN_MAX,
					       HM1092_AGAIN_STEP,
					       HM1092_AGAIN_DEFAULT);

	hm->digital_gain = v4l2_ctrl_new_std(handler, &hm1092_ctrl_ops,
					      V4L2_CID_DIGITAL_GAIN,
					      HM1092_DGAIN_MIN,
					      HM1092_DGAIN_MAX,
					      HM1092_DGAIN_STEP,
					      HM1092_DGAIN_DEFAULT);

	hm->test_pattern = v4l2_ctrl_new_std_menu_items(handler,
							 &hm1092_ctrl_ops,
							 V4L2_CID_TEST_PATTERN,
							 ARRAY_SIZE(hm1092_test_pattern_menu) - 1,
							 0, 0,
							 hm1092_test_pattern_menu);

	if (handler->error) {
		ret = handler->error;
		v4l2_ctrl_handler_free(handler);
		return ret;
	}

	hm->sd.ctrl_handler = handler;
	return 0;
}

static int hm1092_enum_mbus_code(struct v4l2_subdev *sd,
				  struct v4l2_subdev_state *state,
				  struct v4l2_subdev_mbus_code_enum *code)
{
	if (code->index > 0)
		return -EINVAL;

	code->code = HM1092_MBUS_CODE;
	return 0;
}

static int hm1092_enum_frame_size(struct v4l2_subdev *sd,
				   struct v4l2_subdev_state *state,
				   struct v4l2_subdev_frame_size_enum *fse)
{
	if (fse->index > 0 || fse->code != HM1092_MBUS_CODE)
		return -EINVAL;

	fse->min_width = HM1092_WIDTH;
	fse->max_width = HM1092_WIDTH;
	fse->min_height = HM1092_HEIGHT;
	fse->max_height = HM1092_HEIGHT;
	return 0;
}

static int hm1092_set_format(struct v4l2_subdev *sd,
			      struct v4l2_subdev_state *state,
			      struct v4l2_subdev_format *fmt)
{
	struct v4l2_mbus_framefmt *mf = &fmt->format;

	/* Fixed format — only 648x368 GR1P (matches Dell production graph_settings) */
	mf->width = HM1092_WIDTH;
	mf->height = HM1092_HEIGHT;
	mf->code = HM1092_MBUS_CODE;
	mf->field = V4L2_FIELD_NONE;
	mf->colorspace = V4L2_COLORSPACE_RAW;
	mf->ycbcr_enc = V4L2_YCBCR_ENC_DEFAULT;
	mf->quantization = V4L2_QUANTIZATION_DEFAULT;
	mf->xfer_func = V4L2_XFER_FUNC_NONE;

	if (fmt->which == V4L2_SUBDEV_FORMAT_TRY)
		*v4l2_subdev_state_get_format(state, fmt->pad) = *mf;

	return 0;
}

static int hm1092_get_format(struct v4l2_subdev *sd,
			      struct v4l2_subdev_state *state,
			      struct v4l2_subdev_format *fmt)
{
	struct v4l2_mbus_framefmt *mf;

	if (fmt->which == V4L2_SUBDEV_FORMAT_TRY) {
		mf = v4l2_subdev_state_get_format(state, fmt->pad);
		fmt->format = *mf;
	} else {
		fmt->format.width = HM1092_WIDTH;
		fmt->format.height = HM1092_HEIGHT;
		fmt->format.code = HM1092_MBUS_CODE;
		fmt->format.field = V4L2_FIELD_NONE;
		fmt->format.colorspace = V4L2_COLORSPACE_RAW;
		fmt->format.ycbcr_enc = V4L2_YCBCR_ENC_DEFAULT;
		fmt->format.quantization = V4L2_QUANTIZATION_DEFAULT;
		fmt->format.xfer_func = V4L2_XFER_FUNC_NONE;
	}
	return 0;
}

/*
 * TEST 3: periodic AE-kick worker. Writes 0x0104=0x01 to the sensor at the
 * cadence configured via the ae_kick_period_ms module param, mimicking the
 * AE group-hold trigger Windows fires every ~132ms while streaming. Self-
 * reschedules until cancelled in hm1092_set_stream(0).
 */
static void hm1092_ae_kick_work_fn(struct work_struct *work)
{
	struct hm1092 *hm = container_of(to_delayed_work(work),
					 struct hm1092, ae_kick_work);
	struct i2c_client *client = v4l2_get_subdevdata(&hm->sd);
	int ret;

	if (!hm->streaming || !ae_kick_period_ms)
		return;

	ret = hm1092_write_reg(client, 0x0104, 0x01);
	if (ret)
		dev_warn(&client->dev,
			 "ae_kick 0x0104=0x01 failed: %d (stopping kicks)\n", ret);
	else
		schedule_delayed_work(&hm->ae_kick_work,
				      msecs_to_jiffies(ae_kick_period_ms));
}

static int hm1092_set_stream(struct v4l2_subdev *sd, int enable)
{
	struct hm1092 *hm = to_hm1092(sd);
	struct i2c_client *client = v4l2_get_subdevdata(sd);
	int ret;

	dev_info(&client->dev, "hm1092_set_stream: enable=%d ENTER\n", enable);

	if (enable) {
		ret = pm_runtime_resume_and_get(&client->dev);
		dev_info(&client->dev, "  pm_runtime_resume_and_get returned %d\n", ret);
		if (ret && ret != -EACCES)
			return ret;

		/*
		 * Diagnostic mode for a capture-faithful dual-sensor replay.  The
		 * IPU receiver must be listening before userspace replays Windows'
		 * interleaved HM1092/OV08x40 writes and intact 0x0830 transaction.
		 * Probe already holds the sensor rails and MCLK, so leave sensor I2C
		 * completely untouched here and only arm the media pipeline.
		 */
		if (external_stream_control) {
			if (hm->ir_led)
				gpiod_set_value_cansleep(hm->ir_led, 1);
			hm->streaming = true;
			dev_info(&client->dev,
				 "  external_stream_control=1: IPU armed; sensor programming deferred to capture replay\n");
			return 0;
		}

		/*
		 * HYP#11: replay Windows' per-session dvdd GPIO write event.
		 * The dvdd "regulator" is bridge VGPO pin1 — the disable/
		 * enable pair below emits the exact USBIO GPIO-write commands
		 * (pin1=0, pin1=1) Windows sends around every Hello session.
		 * The bridge firmware terminates these writes and may use
		 * them to arm port-2 MIPI forwarding. NOTHING may touch the
		 * sensor's I2C address (0x24) while dvdd is low.
		 */
		if (dvdd_cycle_ms && hm->dvdd) {
			dev_info(&client->dev,
				 "  HYP#11: cycling dvdd (bridge VGPO pin1) off for %u ms...\n",
				 dvdd_cycle_ms);
			regulator_disable(hm->dvdd);
			/*
			 * rmmod leaks a use_count on INT3472:00-dvdd (devm
			 * frees the consumer while enabled), so after any
			 * module reload a single disable never reaches 0 and
			 * the VGPO pin never physically moves (verified via
			 * usbmon: zero USB traffic). Force it off so the
			 * bridge actually sees the write event.
			 */
			if (regulator_is_enabled(hm->dvdd) > 0) {
				dev_warn(&client->dev,
					 "  HYP#11: dvdd still on after disable (leaked use_count) — forcing off\n");
				regulator_force_disable(hm->dvdd);
			}
			msleep(dvdd_cycle_ms);
			ret = regulator_enable(hm->dvdd);
			if (ret) {
				dev_err(&client->dev,
					"  HYP#11: dvdd re-enable FAILED: %d — aborting stream\n",
					ret);
				goto err_rpm;
			}
			/* Windows: dvdd=1 → first sensor I2C = 1.6ms */
			usleep_range(3000, 4000);
			if (regulator_is_enabled(hm->dvdd) <= 0)
				dev_err(&client->dev,
					"  HYP#11: dvdd NOT physically on after re-enable — refcount poisoned (reboot needed), TEST INVALID\n");
			else
				dev_info(&client->dev,
					 "  HYP#11: dvdd back on, proceeding with sensor init\n");
		}

		/*
		 * Write init sequence. If arm_at_entry is set we only write the
		 * head here; the tail is written AFTER MODE_SELECT=0x01 below,
		 * replaying Windows' order.
		 */
		{
			size_t total = ARRAY_SIZE(hm1092_init_regs);
			size_t head = (arm_at_entry && arm_at_entry < total)
				      ? arm_at_entry : total;

			if (head != total)
				dev_info(&client->dev,
					 "  ARMORDER: writing head %zu/%zu, tail %zu deferred until after arm\n",
					 head, total, total - head);
			else
				dev_info(&client->dev,
					 "  writing %zu-entry init sequence...\n", total);

			ret = hm1092_write_reg_list(client, hm1092_init_regs, head);
			if (ret) {
				dev_err(&client->dev, "init sequence failed: %d\n", ret);
				goto err_rpm;
			}
			dev_info(&client->dev, "  init sequence written OK\n");
		}

		/* Apply controls */
		ret = __v4l2_ctrl_handler_setup(&hm->ctrl_handler);
		if (ret) {
			dev_err(&client->dev, "ctrl setup failed: %d\n", ret);
			goto err_rpm;
		}
		dev_info(&client->dev, "  v4l2 controls applied OK\n");

		/* Start streaming */
		dev_info(&client->dev, "  writing MODE_SELECT=0x01 (streaming)...\n");
		ret = hm1092_write_reg(client, HM1092_REG_MODE_SELECT,
				       HM1092_MODE_STREAMING);
		if (ret) {
			dev_err(&client->dev, "stream start failed: %d\n", ret);
			goto err_rpm;
		}
		dev_info(&client->dev, "  MODE_SELECT=0x01 ack'd by sensor\n");

		/*
		 * Windows-faithful tail: the remaining entries (its AE groups)
		 * are written while the sensor is already streaming.
		 */
		if (arm_at_entry && arm_at_entry < ARRAY_SIZE(hm1092_init_regs)) {
			size_t tail = ARRAY_SIZE(hm1092_init_regs) - arm_at_entry;

			ret = hm1092_write_reg_list(client,
						    &hm1092_init_regs[arm_at_entry],
						    tail);
			if (ret)
				dev_warn(&client->dev,
					 "  ARMORDER: post-arm tail failed: %d\n", ret);
			else
				dev_info(&client->dev,
					 "  ARMORDER: wrote %zu post-arm entries while streaming\n",
					 tail);
		}

		/*
		 * TEST 2 instrumentation: dump key sensor regs that may be
		 * chip-specific (OTP/calibration). If our blind init writes
		 * stomp values that should be preserved per-chip, this read
		 * shows it.
		 */
		if (dump_regs_on_stream) {
			u8 v_4b20 = 0xff, v_0101 = 0xff;
			hm1092_read_reg(client, 0x4b20, &v_4b20);
			hm1092_read_reg(client, 0x0101, &v_0101);
			dev_info(&client->dev,
				 "  REG_DUMP: 0x4b20=0x%02x (init writes 0x9e), 0x0101=0x%02x (init writes 0x03)\n",
				 v_4b20, v_0101);
		}

		/*
		 * TEST 1: Optional delay between sensor MODE_SELECT=0x01 and
		 * bridge mipi-ir config. Windows trace has ~182ms between these
		 * two events. We do them in <3ms by default. If the bridge needs
		 * the sensor PLL to stabilize before configuring port 2, this
		 * delay matters.
		 */
		if (mipi_ir_delay_ms) {
			dev_info(&client->dev,
				 "  sleeping %u ms before bridge mipi-ir config (Windows-Hello ordering)...\n",
				 mipi_ir_delay_ms);
			msleep(mipi_ir_delay_ms);
		}

		/*
		 * TEST 2: log MCLK rate right before we tell the bridge to
		 * forward port 2. If the rate has gone to 0, INT3472 / tps68470
		 * silently cut the clock during our flow and bridge will reach
		 * a "no MCLK seen" state on port 2. Defensive: re-prepare/
		 * enable to bump refcount and force MCLK on.
		 */
		if (hm->extclk) {
			unsigned long pre_rate = clk_get_rate(hm->extclk);
			int clk_ret = clk_prepare_enable(hm->extclk);
			unsigned long post_rate = clk_get_rate(hm->extclk);
			if (!clk_ret)
				hm->stream_clock_enabled = true;
			dev_info(&client->dev,
				 "  MCLK pre=%lu Hz, defensive clk_prepare_enable returned %d, post=%lu Hz\n",
				 pre_rate, clk_ret, post_rate);
		}

		/*
		 * Now that sensor is clocking the CSI-2 lane, ask intel_cvs to
		 * fire HOST_SET_MIPI_CONFIG (0x0830) for IR/port-2. This is the
		 * Windows ordering: sensor 0x0100=0x01 FIRST, bridge 0x830
		 * AFTER, so the bridge sees an active port-2 input when
		 * it processes the config. Previously we did it backwards and
		 * port 2 stayed silent.
		 */
		if (!send_bridge_config) {
			dev_info(&client->dev,
				 "  bridge mipi-ir config skipped by module parameter\n");
		} else if (cvs_send_mipi_ir_config) {
			int cvs_ret = cvs_send_mipi_ir_config();
			dev_info(&client->dev,
				 "  intel_cvs port-2 mipi config returned %d\n",
				 cvs_ret);
		} else {
			dev_warn(&client->dev,
				 "  intel_cvs symbol unavailable; port-2 forwarding NOT configured\n");
		}

		/*
		 * TEST 2 (continued): log MCLK rate AFTER 0x830 too. If it went
		 * to 0 here, the bridge's processing of 0x830 itself disabled
		 * the clock. If it's still on, MCLK isn't the issue.
		 */
		if (hm->extclk) {
			unsigned long after_rate = clk_get_rate(hm->extclk);
			dev_info(&client->dev,
				 "  MCLK after 0x830: %lu Hz\n", after_rate);
		}

		/* Lazy-enable IR LED only while streaming */
		hm1092_ir_led_set(hm, true);
		dev_info(&client->dev, "  IR LED set to 1 (%s)\n",
			 hm->ir_led_cdev ? "led" : hm->ir_led ? "gpio" : "absent");

		hm->streaming = true;

		/* TEST 3: kick off periodic AE-trigger writes if enabled */
		if (ae_kick_period_ms) {
			dev_info(&client->dev,
				 "  scheduling AE-kick (0x0104=0x01) every %u ms\n",
				 ae_kick_period_ms);
			schedule_delayed_work(&hm->ae_kick_work,
					      msecs_to_jiffies(ae_kick_period_ms));
		}

		dev_info(&client->dev, "hm1092_set_stream(1) EXIT — sensor is now streaming\n");
	} else {
		hm->streaming = false;

		/* Cancel any pending AE-kick before sensor goes to standby */
		cancel_delayed_work_sync(&hm->ae_kick_work);

		/* Balance the defensive clk_prepare_enable() from set_stream(1) */
		if (hm->stream_clock_enabled) {
			clk_disable_unprepare(hm->extclk);
			hm->stream_clock_enabled = false;
		}

		/* Turn off IR LED before sensor goes to standby */
		hm1092_ir_led_set(hm, false);

		ret = hm1092_write_reg(client, HM1092_REG_MODE_SELECT,
				       HM1092_MODE_STANDBY);
		dev_info(&client->dev, "  MODE_SELECT=0x00 (standby) write returned %d\n", ret);

		if (send_bridge_config && cvs_send_mipi_rgb_config) {
			int cvs_ret = cvs_send_mipi_rgb_config();
			dev_info(&client->dev,
				 "  intel_cvs restored port-0 RGB mipi config returned %d\n",
				 cvs_ret);
		}

		pm_runtime_put_noidle(&client->dev);
		dev_info(&client->dev, "hm1092_set_stream(0) EXIT\n");
	}

	return 0;

err_rpm:
	pm_runtime_put(&client->dev);
	dev_info(&client->dev, "hm1092_set_stream EXIT with error %d\n", ret);
	return ret;
}

/*
 * sysfs `stream` attribute — manual hook to invoke hm1092_set_stream()
 * directly, bypassing the V4L2 pipeline's s_stream propagation. This is a
 * diagnostic tool: when v4l2-ctl STREAMON on /dev/video16 fails to walk up
 * to this sensor (because the ipu7-isys driver hands off to firmware and
 * never calls v4l2_subdev_call(sd, video, s_stream, 1)), we can drive the
 * sensor manually:
 *     echo 1 > /sys/bus/i2c/devices/i2c-HIMX1092:00/stream
 *     <run capture>
 *     echo 0 > /sys/bus/i2c/devices/i2c-HIMX1092:00/stream
 */
static ssize_t stream_show(struct device *dev,
			   struct device_attribute *attr, char *buf)
{
	struct v4l2_subdev *sd = dev_get_drvdata(dev);
	struct hm1092 *hm = to_hm1092(sd);

	return sprintf(buf, "%d\n", hm->streaming ? 1 : 0);
}

static ssize_t stream_store(struct device *dev,
			    struct device_attribute *attr,
			    const char *buf, size_t count)
{
	struct v4l2_subdev *sd = dev_get_drvdata(dev);
	int enable, ret;

	if (kstrtoint(buf, 0, &enable))
		return -EINVAL;

	ret = hm1092_set_stream(sd, !!enable);
	if (ret < 0)
		return ret;

	return count;
}
static DEVICE_ATTR_RW(stream);

static int hm1092_init_state(struct v4l2_subdev *sd,
			      struct v4l2_subdev_state *state)
{
	struct v4l2_subdev_format fmt = {
		.which = V4L2_SUBDEV_FORMAT_TRY,
		.pad = 0,
	};

	return hm1092_set_format(sd, state, &fmt);
}

static const struct v4l2_subdev_video_ops hm1092_video_ops = {
	.s_stream = hm1092_set_stream,
};

/*
 * libcamera (and anything else following
 * Documentation/driver-api/media/v4l2-subdev.rst) queries the sensor's crop
 * rectangles to learn the pixel array geometry. Without this it logs
 * "Failed to retrieve the sensor crop rectangle" and
 * "The sensor kernel driver needs to be fixed", then falls back to defaults.
 *
 * The HM1092 pixel array is 1280x720. The mode we expose is the 2x2 binned
 * 640x360 window plus 8px of overscan on each axis, which is what Windows
 * programs via registers 0x0344-0x034F, giving 648x368 out of a 1293x733
 * analogue crop.
 */
static int hm1092_get_selection(struct v4l2_subdev *sd,
				struct v4l2_subdev_state *sd_state,
				struct v4l2_subdev_selection *sel)
{
	if (sel->pad != 0)
		return -EINVAL;

	switch (sel->target) {
	case V4L2_SEL_TGT_CROP:
	case V4L2_SEL_TGT_CROP_DEFAULT:
	case V4L2_SEL_TGT_CROP_BOUNDS:
		sel->r.left = 0;
		sel->r.top = 0;
		sel->r.width = HM1092_WIDTH;
		sel->r.height = HM1092_HEIGHT;
		return 0;
	case V4L2_SEL_TGT_NATIVE_SIZE:
		sel->r.left = 0;
		sel->r.top = 0;
		sel->r.width = HM1092_NATIVE_WIDTH;
		sel->r.height = HM1092_NATIVE_HEIGHT;
		return 0;
	default:
		return -EINVAL;
	}
}

static const struct v4l2_subdev_pad_ops hm1092_pad_ops = {
	.enum_mbus_code = hm1092_enum_mbus_code,
	.enum_frame_size = hm1092_enum_frame_size,
	.get_fmt = hm1092_get_format,
	.set_fmt = hm1092_set_format,
	.get_selection = hm1092_get_selection,
};

static const struct v4l2_subdev_ops hm1092_subdev_ops = {
	.video = &hm1092_video_ops,
	.pad = &hm1092_pad_ops,
};

static const struct v4l2_subdev_internal_ops hm1092_internal_ops = {
	.init_state = hm1092_init_state,
};

/* --- Probe / Remove --- */

static int hm1092_check_chip_id(struct i2c_client *client)
{
	u16 chip_id;
	int ret;

	ret = hm1092_read_reg16(client, HM1092_REG_CHIP_ID, &chip_id);
	if (ret) {
		dev_err(&client->dev,
			"Failed to read chip ID (sensor may not be powered): %d\n",
			ret);
		/*
		 * Return -ENODEV for ANY I2C failure — never -ETIMEDOUT or
		 * -EPROBE_DEFER. The kernel retries deferred probes, and on
		 * this USBIO bridge, repeated I2C timeouts crash the USB bus
		 * and kill all devices on it (including the working RGB camera).
		 */
		return -ENODEV;
	}

	if (chip_id != HM1092_CHIP_ID) {
		dev_err(&client->dev,
			"Chip ID mismatch: expected 0x%04x, got 0x%04x\n",
			HM1092_CHIP_ID, chip_id);
		return -ENODEV;
	}

	dev_info(&client->dev, "HM1092 chip ID confirmed: 0x%04x\n", chip_id);
	return 0;
}

static void hm1092_power_off(struct hm1092 *hm)
{
	if (hm->stream_clock_enabled) {
		clk_disable_unprepare(hm->extclk);
		hm->stream_clock_enabled = false;
	}
	if (hm->extclk_enabled) {
		clk_disable_unprepare(hm->extclk);
		hm->extclk_enabled = false;
	}
	if (hm->dvdd_enabled) {
		regulator_disable(hm->dvdd);
		hm->dvdd_enabled = false;
	}
	if (hm->avdd_enabled) {
		regulator_disable(hm->avdd);
		hm->avdd_enabled = false;
	}
	if (hm->dovdd_enabled) {
		regulator_disable(hm->dovdd);
		hm->dovdd_enabled = false;
	}
}

static int hm1092_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct hm1092 *hm;
	int ret;

	hm = devm_kzalloc(dev, sizeof(*hm), GFP_KERNEL);
	if (!hm)
		return -ENOMEM;

	v4l2_i2c_subdev_init(&hm->sd, client, &hm1092_subdev_ops);
	hm->sd.internal_ops = &hm1092_internal_ops;

	/* TEST 3: init delayed_work for optional AE-kick */
	INIT_DELAYED_WORK(&hm->ae_kick_work, hm1092_ae_kick_work_fn);

	/*
	 * Request power supplies from INT3472. Use devm_regulator_get_optional
	 * so we don't block on missing regulators — not all supplies may exist.
	 */
	hm->dvdd = devm_regulator_get_optional(dev, "dvdd");
	if (IS_ERR(hm->dvdd)) {
		if (PTR_ERR(hm->dvdd) == -EPROBE_DEFER)
			return -EPROBE_DEFER;
		hm->dvdd = NULL;
	}

	hm->avdd = devm_regulator_get_optional(dev, "avdd");
	if (IS_ERR(hm->avdd)) {
		if (PTR_ERR(hm->avdd) == -EPROBE_DEFER)
			return -EPROBE_DEFER;
		hm->avdd = NULL;
	}

	hm->dovdd = devm_regulator_get_optional(dev, "dovdd");
	if (IS_ERR(hm->dovdd)) {
		if (PTR_ERR(hm->dovdd) == -EPROBE_DEFER)
			return -EPROBE_DEFER;
		hm->dovdd = NULL;
	}

	/* Enable supplies, recording only successful enables for unwind/remove. */
	if (hm->dovdd) {
		ret = regulator_enable(hm->dovdd);
		if (ret) {
			dev_err(dev, "Failed to enable dovdd: %d\n", ret);
			goto err_power;
		}
		hm->dovdd_enabled = true;
	}
	if (hm->avdd) {
		ret = regulator_enable(hm->avdd);
		if (ret) {
			dev_err(dev, "Failed to enable avdd: %d\n", ret);
			goto err_power;
		}
		hm->avdd_enabled = true;
	}
	if (hm->dvdd) {
		ret = regulator_enable(hm->dvdd);
		if (ret) {
			dev_err(dev, "Failed to enable dvdd: %d\n", ret);
			goto err_power;
		}
		hm->dvdd_enabled = true;
	}

	/* Get and enable reference clock from INT3472 */
	hm->extclk = devm_clk_get_optional(dev, NULL);
	if (IS_ERR(hm->extclk)) {
		ret = PTR_ERR(hm->extclk);
		if (ret == -EPROBE_DEFER)
			goto err_power;
		hm->extclk = NULL;
	}
	if (hm->extclk) {
		ret = clk_prepare_enable(hm->extclk);
		if (ret) {
			dev_err(dev, "Failed to enable extclk: %d\n", ret);
			goto err_power;
		}
		hm->extclk_enabled = true;
	}

	/*
	 * Get IR LED GPIO — mapped by INT3472 type 0x02 as "ir-led".
	 * Acquire OUT_LOW (off). Lazy-enable: LED turns on only when
	 * sensor enters streaming mode (hm1092_set_stream), turns off
	 * on stream stop or driver unload. Matches Windows behavior;
	 * avoids the IR-emitter-always-on power/eye-exposure issue.
	 */
	hm->ir_led = devm_gpiod_get_optional(dev, "ir-led", GPIOD_OUT_LOW);
	if (IS_ERR(hm->ir_led)) {
		ret = PTR_ERR(hm->ir_led);
		if (ret == -EPROBE_DEFER)
			goto err_power;
		hm->ir_led = NULL;
	}

	/* The path that actually resolves on INT3472 STROBE machines. */
	hm->ir_led_cdev = devm_led_get(dev, "ir_flood");
	if (IS_ERR(hm->ir_led_cdev)) {
		ret = PTR_ERR(hm->ir_led_cdev);
		if (ret == -EPROBE_DEFER)
			goto err_power;
		hm->ir_led_cdev = NULL;
	}
	if (hm->ir_led_cdev)
		led_set_brightness(hm->ir_led_cdev, 0);

	dev_info(dev, "Power: dvdd=%s avdd=%s dovdd=%s clk=%s (%lu Hz) ir_led=%s\n",
		 hm->dvdd ? "found" : "none",
		 hm->avdd ? "found" : "none",
		 hm->dovdd ? "found" : "none",
		 hm->extclk ? "found" : "none",
		 hm->extclk ? clk_get_rate(hm->extclk) : 0,
		 (hm->ir_led || hm->ir_led_cdev) ? "found (off — lazy)" : "none");

	/* Give sensor time to boot after power-on */
	usleep_range(20000, 25000);

	/* Verify chip identity */
	ret = hm1092_check_chip_id(client);
	if (ret)
		goto err_power;

	/* Put back to standby, keep power for later streaming */
	hm1092_write_reg(client, HM1092_REG_MODE_SELECT, HM1092_MODE_STANDBY);

	/* Initialize controls */
	ret = hm1092_init_controls(hm);
	if (ret) {
		dev_err(dev, "Failed to init controls: %d\n", ret);
		goto err_power;
	}

	/* Register media entity */
	hm->pad.flags = MEDIA_PAD_FL_SOURCE;
	hm->sd.flags |= V4L2_SUBDEV_FL_HAS_DEVNODE;
	hm->sd.entity.function = MEDIA_ENT_F_CAM_SENSOR;
	ret = media_entity_pads_init(&hm->sd.entity, 1, &hm->pad);
	if (ret) {
		dev_err(dev, "Failed to init media entity: %d\n", ret);
		goto err_ctrl;
	}

	/* Register V4L2 subdevice */
	ret = v4l2_async_register_subdev_sensor(&hm->sd);
	if (ret) {
		dev_err(dev, "Failed to register v4l2 subdev: %d\n", ret);
		goto err_media;
	}

	pm_runtime_set_active(dev);
	pm_runtime_enable(dev);
	pm_runtime_idle(dev);

	/* Diagnostic: manual sensor-stream trigger. Non-fatal if it fails. */
	ret = device_create_file(dev, &dev_attr_stream);
	if (ret)
		dev_warn(dev, "Failed to create sysfs 'stream' attr: %d\n", ret);
	else
		dev_info(dev, "sysfs 'stream' attr ready at /sys/bus/i2c/devices/i2c-HIMX1092:00/stream\n");

	dev_info(dev, "HM1092 IR sensor driver probed successfully\n");
	return 0;

err_media:
	media_entity_cleanup(&hm->sd.entity);
err_ctrl:
	v4l2_ctrl_handler_free(&hm->ctrl_handler);
	err_power:
	hm1092_power_off(hm);
	return ret;
}

static void hm1092_remove(struct i2c_client *client)
{
	struct v4l2_subdev *sd = i2c_get_clientdata(client);
	struct hm1092 *hm = to_hm1092(sd);

	device_remove_file(&client->dev, &dev_attr_stream);

	/* Ensure any pending AE-kick is cancelled before we tear down */
	cancel_delayed_work_sync(&hm->ae_kick_work);

	/* Safety: ensure IR LED is off on driver unload */
	hm1092_ir_led_set(hm, false);

	v4l2_async_unregister_subdev(sd);
	media_entity_cleanup(&sd->entity);
	v4l2_ctrl_handler_free(&hm->ctrl_handler);
	pm_runtime_disable(&client->dev);

	/*
	 * Release the rails probe enabled. Without this, every module
	 * reload leaks one use_count on INT3472:00-dvdd (the devm consumer
	 * is freed while enabled — that's the rmmod regulator WARN), after
	 * which regulator_disable() at stream time can never reach 0 and
	 * the bridge VGPO pin never physically moves (HYP#11 test invalid).
	 */
	hm1092_power_off(hm);
}

static const struct acpi_device_id hm1092_acpi_ids[] = {
	{ "HIMX1092" },
	{ }
};
MODULE_DEVICE_TABLE(acpi, hm1092_acpi_ids);

static struct i2c_driver hm1092_i2c_driver = {
	.driver = {
		.name = "hm1092",
		.acpi_match_table = hm1092_acpi_ids,
	},
	.probe = hm1092_probe,
	.remove = hm1092_remove,
};
module_i2c_driver(hm1092_i2c_driver);

MODULE_AUTHOR("Contributors");
MODULE_DESCRIPTION("Himax HM1092 IR camera sensor driver");
MODULE_LICENSE("GPL");
