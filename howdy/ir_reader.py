# Howdy recorder for the HM1092 IR sensor on Intel IPU7.
#
# WHY A DEDICATED READER
#   The HM1092 is a MONOCHROME sensor that the driver tags SGRBG10 (Bayer GRBG),
#   because that is what Windows/the IPU graph settings declare. Anything that
#   honours that tag -- libcamera's SoftwareIsp, and therefore the PipeWire path
#   -- DEBAYERS mono data, and PipeWire additionally renegotiates the stream to
#   1920x1080 and lands the 648x368 payload in a mostly-black buffer.
#
#   Reading the V4L2 node directly and treating the data as what it physically
#   is -- 10-bit greyscale -- produces a clean, correctly framed IR image.
#
# FRAME LAYOUT (measured on this hardware)
#   648x368, V4L2_PIX_FMT_SGRBG10 ('BA10'), bytesperline = 1344.
#   That is 672 pixels of stride for 648 active, 16-bit little-endian
#   containers holding 10-bit values (0..1023).
#
# PREREQUISITE
#   The sensor's V4L2 control is named `link_frequency` (NOT link_freq) and must
#   select 180,480,000 -- the DDR clock. Publishing the 360,960,000 bit rate made
#   isys run the D-PHY at 721 Mbps against a sensor sending ~361, so the clock
#   lane toggled but no data packet ever framed. The hm1092 driver built
#   2026-07-25 defaults to the corrected value.

import fcntl
import mmap
import os
import re
import ctypes
import subprocess
import numpy

from recorders import v4l2
from cv2 import cvtColor, COLOR_GRAY2BGR, CAP_PROP_FRAME_WIDTH, CAP_PROP_FRAME_HEIGHT
try:
	from i18n import _
except ImportError:
	def _(text):
		return text

# 'BA10' = V4L2_PIX_FMT_SGRBG10
PIX_FMT_SGRBG10 = 0x30314142
NBUF = 4

# The IR flood illuminator. INT3472 claims this GPIO and exposes it as a LED
# class device, which is why the hm1092 driver reports ir_led=none and cannot
# drive it itself -- so the recorder must. Without it the scene is lit only by
# ambient IR and frames come back too dark for Howdy's dark_threshold.
IR_LED = "/sys/class/leds/HIMX1092_00::ir_flood_led/brightness"


# Bind os.open/os.write at import time. release() can run from
# VideoCapture.__del__ during interpreter shutdown, by which point builtins
# (including `open`) may already be torn down -- that raised NameError and left
# the IR illuminator switched ON after every authentication.
_os_open, _os_write, _os_close, _O_WRONLY = os.open, os.write, os.close, os.O_WRONLY


def _set_ir_led(on):
	try:
		fd = _os_open(IR_LED, _O_WRONLY)
		try:
			_os_write(fd, b"1" if on else b"0")
		finally:
			_os_close(fd)
		return True
	except BaseException:
		# never let illuminator control break capture or teardown
		return False


SENSOR_ENTITY = "hm1092"
# The CSI-2 port the sensor is wired to is NOT the same on every machine: it is
# port 2 on the Dell XPS 16 (DA16260) and port 1 on the Dell Pro 14, and the
# bridge's ACPI id differs too (INTC10E1 vs INTC10DE). Discover it by following
# the sensor's own link in the media graph rather than hardcoding a port.
FMT = "SGRBG10_1X10/648x368"


def _find_csi2_for(topo, sensor):
	"""Return the CSI-2 entity that the sensor's source pad feeds."""
	in_sensor = False
	for line in topo.splitlines():
		t = line.strip()
		if re.match(r"- entity \d+: %s\b" % re.escape(sensor), t):
			in_sensor = True
			continue
		if in_sensor and t.startswith("- entity"):
			break
		if in_sensor:
			m = re.search(r'-> "([^"]*CSI2[^"]*)"', line)
			if m:
				return m.group(1)
	return None


def _topology(dev):
	try:
		return subprocess.run(["media-ctl", "-d", dev, "-p"],
				      capture_output=True, text=True, timeout=10).stdout
	except (OSError, subprocess.SubprocessError):
		return ""


def configure_pipeline():
	"""Set pad formats and enable the CSI2 -> capture link; return the node.

	On a fresh boot the IPU7 media graph comes up with that link DISABLED and
	the CSI-2 pads at their 4096x3072 default, so a bare VIDIOC_STREAMON on the
	capture node yields ZERO frames. libcamera normally performs this setup,
	but we deliberately bypass libcamera (it debayers this mono sensor), so the
	reader must do it itself.

	Resolved entirely BY ENTITY NAME: /dev/videoN, /dev/v4l-subdevN and
	libcamera indexes all shuffle between boots on this platform.
	"""
	for dev in sorted("/dev/" + d for d in os.listdir("/dev") if d.startswith("media")):
		topo = _topology(dev)
		if SENSOR_ENTITY not in topo:
			continue

		sensor = None
		for line in topo.splitlines():
			m = re.match(r"- entity \d+: (%s[^(]*)" % SENSOR_ENTITY, line.strip())
			if m:
				sensor = m.group(1).strip()
				break
		if not sensor:
			continue

		csi2 = _find_csi2_for(topo, sensor)
		if not csi2:
			continue

		cap, in_csi = None, False
		for line in topo.splitlines():
			t = line.strip()
			if re.match(r"- entity \d+: %s\b" % re.escape(csi2), t):
				in_csi = True
				continue
			if in_csi and t.startswith("- entity"):
				break
			if in_csi:
				m = re.search(r'-> "([^"]*Capture[^"]*)"', line)
				if m:
					cap = m.group(1)
					break
		if not cap:
			continue

		for args in (
			["--set-v4l2", '"%s":0 [fmt:%s]' % (sensor, FMT)],
			["--set-v4l2", '"%s":0 [fmt:%s]' % (csi2, FMT)],
			["--set-v4l2", '"%s":1 [fmt:%s]' % (csi2, FMT)],
			["-l", '"%s":1 -> "%s":0 [1]' % (csi2, cap)],
		):
			try:
				subprocess.run(["media-ctl", "-d", dev] + args,
					       capture_output=True, timeout=10)
			except (OSError, subprocess.SubprocessError):
				pass

		ent = None
		for line in _topology(dev).splitlines():
			m = re.match(r"- entity \d+: (.+?)( \(|$)", line.strip())
			if m:
				ent = m.group(1).strip()
			if "device node name /dev/video" in line and ent == cap:
				return line.strip().split()[-1]
		return None
	return None


class ir_reader:
	"""Looks like the subset of cv2.VideoCapture that Howdy actually uses."""

	def __init__(self, device_name, device_format=None):
		self.device_name = device_name
		self.width = 648
		self.height = 368
		self.bytesperline = 1344
		self.fd = None
		self.buffers = []
		self.streaming = False
		self.led_on = False
		# Configure the media graph FIRST. Without this, a fresh boot has the
		# CSI2 -> capture link disabled and streaming returns no frames at all.
		discovered = configure_pipeline()
		if discovered and discovered != device_name:
			# node numbers shuffle between boots -- trust the graph over config.ini
			self.device_name = discovered
		self._open()

	# -- cv2-compatible getters/setters --------------------------------------
	def set(self, prop, setting):
		if prop == CAP_PROP_FRAME_WIDTH:
			self.width = int(setting)
		elif prop == CAP_PROP_FRAME_HEIGHT:
			self.height = int(setting)

	def get(self, prop):
		if prop == CAP_PROP_FRAME_WIDTH:
			return self.width
		elif prop == CAP_PROP_FRAME_HEIGHT:
			return self.height
		return 0

	def isOpened(self):
		return self.fd is not None

	# -- device setup ---------------------------------------------------------
	def _open(self):
		self.fd = os.open(self.device_name, os.O_RDWR)

		fmt = v4l2.v4l2_format()
		fmt.type = v4l2.V4L2_BUF_TYPE_VIDEO_CAPTURE
		fmt.fmt.pix.width = self.width
		fmt.fmt.pix.height = self.height
		fmt.fmt.pix.pixelformat = PIX_FMT_SGRBG10
		fmt.fmt.pix.field = v4l2.V4L2_FIELD_NONE
		fcntl.ioctl(self.fd, v4l2.VIDIOC_S_FMT, fmt)

		# the driver may hand back a different stride than we asked for
		self.width = fmt.fmt.pix.width
		self.height = fmt.fmt.pix.height
		self.bytesperline = fmt.fmt.pix.bytesperline or (self.width * 2)

		req = v4l2.v4l2_requestbuffers()
		req.type = v4l2.V4L2_BUF_TYPE_VIDEO_CAPTURE
		req.memory = v4l2.V4L2_MEMORY_MMAP
		req.count = NBUF
		fcntl.ioctl(self.fd, v4l2.VIDIOC_REQBUFS, req)

		for i in range(req.count):
			buf = v4l2.v4l2_buffer()
			buf.type = v4l2.V4L2_BUF_TYPE_VIDEO_CAPTURE
			buf.memory = v4l2.V4L2_MEMORY_MMAP
			buf.index = i
			fcntl.ioctl(self.fd, v4l2.VIDIOC_QUERYBUF, buf)
			m = mmap.mmap(self.fd, buf.length, mmap.MAP_SHARED,
				      mmap.PROT_READ | mmap.PROT_WRITE,
				      offset=buf.m.offset)
			self.buffers.append(m)
			fcntl.ioctl(self.fd, v4l2.VIDIOC_QBUF, buf)

	def record(self):
		if self.streaming:
			return
		self.led_on = _set_ir_led(True)
		typ = ctypes.c_int(v4l2.V4L2_BUF_TYPE_VIDEO_CAPTURE)
		fcntl.ioctl(self.fd, v4l2.VIDIOC_STREAMON, typ)
		self.streaming = True

	# -- capture --------------------------------------------------------------
	def grab(self):
		self.read()

	def read(self):
		"""Return (ret, BGR ndarray) like cv2.VideoCapture.read()."""
		if self.fd is None:
			return False, None
		if not self.streaming:
			self.record()

		buf = v4l2.v4l2_buffer()
		buf.type = v4l2.V4L2_BUF_TYPE_VIDEO_CAPTURE
		buf.memory = v4l2.V4L2_MEMORY_MMAP
		try:
			fcntl.ioctl(self.fd, v4l2.VIDIOC_DQBUF, buf)
		except OSError:
			return False, None

		raw = self.buffers[buf.index][:self.bytesperline * self.height]
		fcntl.ioctl(self.fd, v4l2.VIDIOC_QBUF, buf)

		# 16-bit LE containers -> drop to 8 bits, then crop the stride padding
		arr = numpy.frombuffer(raw, dtype='<u2')
		arr = arr.reshape(self.height, self.bytesperline // 2)
		arr = arr[:, :self.width]
		gray = (arr >> 2).astype(numpy.uint8)

		return True, cvtColor(gray, COLOR_GRAY2BGR)

	def release(self):
		if self.fd is None:
			return
		try:
			if self.streaming:
				typ = ctypes.c_int(v4l2.V4L2_BUF_TYPE_VIDEO_CAPTURE)
				fcntl.ioctl(self.fd, v4l2.VIDIOC_STREAMOFF, typ)
				self.streaming = False
			for m in self.buffers:
				m.close()
			self.buffers = []
			if self.led_on:
				_set_ir_led(False)
				self.led_on = False
		finally:
			os.close(self.fd)
			self.fd = None


# --- IR illuminator failsafe teardown (omarchy howdy role) -------------------
# The illuminator is pure USERSPACE state: record() writes 1 to the LED sysfs
# node and only release() writes 0. Python's default SIGTERM disposition
# terminates the process immediately -- no finally, no __del__, no atexit -- so
# a SIGTERMed scan left the emitter latched ON.
#
# The failure is invisible without this: the kernel closes the V4L2 fd on
# process death, so the SENSOR stops (hm1092 logs MODE_SELECT=0x00 standby) and
# nothing further reaches the journal, while the emitter keeps burning. The
# hm1092 driver cannot clean up either -- INT3472 claims this GPIO and exposes
# it as a LED class device, which is why the driver reports ir_led=none.
#
# This is the ordinary walk-away path, not a corner case. howdy-face-unlock.sh
# SIGTERMs a scan from its dpms watchdog the moment the display goes dark, and
# again at its `timeout 10` cap; pam_howdy scans for sudo/polkit take a SIGINT
# on Ctrl-C. One such kill (2026-08-13 20:24:20, dpms watchdog) left the
# emitter on for 5h05m on battery with the screen off.
#
# SIGKILL stays unreachable by design -- howdy-face-unlock.sh asserts the LED
# off after every scan and on every lit->dark edge to cover that.

import atexit as _atexit
import signal as _signal

_ir_led_on = False
_set_ir_led_unguarded = _set_ir_led


def _set_ir_led(on):
	"""Track the last state we successfully wrote, so teardown is a no-op."""
	global _ir_led_on
	ok = _set_ir_led_unguarded(on)
	if ok:
		_ir_led_on = bool(on)
	return ok


def _ir_led_failsafe_off():
	if _ir_led_on:
		_set_ir_led(False)


_atexit.register(_ir_led_failsafe_off)


def _ir_led_signal_teardown(signum, _frame):
	"""Douse the illuminator, then die exactly as we would have.

	Restoring SIG_DFL and re-raising preserves the WIFSIGNALED exit status that
	howdy-face-unlock.sh and timeout(1) read to tell a kill from a no-match.
	"""
	_ir_led_failsafe_off()
	_signal.signal(signum, _signal.SIG_DFL)
	os.kill(os.getpid(), signum)


# Claim only signals nobody else is handling, and only from the main thread
# (signal.signal raises ValueError anywhere else). compare.py installs no
# handlers and builds the recorder on the main thread, so these all take.
for _sig in (_signal.SIGTERM, _signal.SIGHUP, _signal.SIGINT):
	try:
		if _signal.getsignal(_sig) in (_signal.SIG_DFL, _signal.default_int_handler):
			_signal.signal(_sig, _ir_led_signal_teardown)
	except (ValueError, OSError, AttributeError):
		pass
