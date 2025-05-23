#!/usr/bin/python3
import time
import os
import subprocess
import logging
from watchdog.observers import Observer
from watchdog.events import *

# Set up logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

WATCH_PATH = "/mnt/usb_share"
ACT_EVENTS = [DirDeletedEvent, DirMovedEvent, FileDeletedEvent, FileModifiedEvent, FileMovedEvent]
ACT_TIME_OUT = 5
GADGET_PATH = "/sys/kernel/config/usb_gadget/g1"
DISK_IMAGE = "/piusb.bin"

class DirtyHandler(FileSystemEventHandler):
    def __init__(self):
        self.reset()

    def on_any_event(self, event):
        if type(event) in ACT_EVENTS:
            self._dirty = True
            self._dirty_time = time.time()

    @property
    def dirty(self):
        return self._dirty

    def dirty_time(self):
        return self._dirty_time

    def reset(self):
        self._dirty = False
        self._dirty_time = 0


def run_command(command):
    try:
        subprocess.run(command, shell=True, check=True)
    except subprocess.CalledProcessError as e:
        logger.error(f"Command failed: {command}\n{e}")


def unmount_gadget():
    if os.path.exists(os.path.join(GADGET_PATH, "UDC")):
        with open(os.path.join(GADGET_PATH, "UDC"), "w") as f:
            f.write("\n")
        time.sleep(1)


def mount_gadget():
    run_command("modprobe libcomposite")
    os.makedirs(GADGET_PATH, exist_ok=True)

    with open(os.path.join(GADGET_PATH, "idVendor"), "w") as f:
        f.write("0x0781")
    with open(os.path.join(GADGET_PATH, "idProduct"), "w") as f:
        f.write("0x5567")
    with open(os.path.join(GADGET_PATH, "bcdDevice"), "w") as f:
        f.write("0x0100")
    with open(os.path.join(GADGET_PATH, "bcdUSB"), "w") as f:
        f.write("0x0200")

    os.makedirs(os.path.join(GADGET_PATH, "strings/0x409"), exist_ok=True)
    with open(os.path.join(GADGET_PATH, "strings/0x409/serialnumber"), "w") as f:
        f.write("4C530001090211117161")
    with open(os.path.join(GADGET_PATH, "strings/0x409/manufacturer"), "w") as f:
        f.write("SanDisk")
    with open(os.path.join(GADGET_PATH, "strings/0x409/product"), "w") as f:
        f.write("Cruzer Blade")

    os.makedirs(os.path.join(GADGET_PATH, "configs/c.1/strings/0x409"), exist_ok=True)
    with open(os.path.join(GADGET_PATH, "configs/c.1/strings/0x409/configuration"), "w") as f:
        f.write("Mass Storage")
    with open(os.path.join(GADGET_PATH, "configs/c.1/MaxPower"), "w") as f:
        f.write("250")

    os.makedirs(os.path.join(GADGET_PATH, "functions/mass_storage.0"), exist_ok=True)
    with open(os.path.join(GADGET_PATH, "functions/mass_storage.0/stall"), "w") as f:
        f.write("0")
    with open(os.path.join(GADGET_PATH, "functions/mass_storage.0/lun.0/file"), "w") as f:
        f.write(DISK_IMAGE)
    with open(os.path.join(GADGET_PATH, "functions/mass_storage.0/lun.0/removable"), "w") as f:
        f.write("1")

    os.symlink(os.path.join(GADGET_PATH, "functions/mass_storage.0"), os.path.join(GADGET_PATH, "configs/c.1/mass_storage.0"))

    with open(os.path.join(GADGET_PATH, "UDC"), "w") as f:
        f.write(os.listdir("/sys/class/udc")[0])


def main():
    logger.info("(Re)Mounting gadget")
    unmount_gadget()
    time.sleep(1)
    mount_gadget()

    evh = DirtyHandler()
    observer = Observer()
    observer.schedule(evh, path=WATCH_PATH, recursive=True)
    observer.start()

    try:
        while True:
            if evh.dirty:
                time_out = time.time() - evh.dirty_time()
                if time_out >= ACT_TIME_OUT:
                    logger.info("Change detected. Resetting USB gadget...")
                    unmount_gadget()
                    run_command("sync")
                    time.sleep(1)
                    mount_gadget()
                    evh.reset()
                time.sleep(1)
            else:
                time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()


if __name__ == "__main__":
    main()
