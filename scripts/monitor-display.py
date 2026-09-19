"""Capture USB diagnostics across deep-sleep disconnects without resetting the board."""
import argparse
import os
from pathlib import Path
import select
import termios
import time

parser=argparse.ArgumentParser()
parser.add_argument("--port",required=True)
parser.add_argument("--seconds",type=int,default=90)
parser.add_argument("--log",type=Path,default=Path(".local/firmware/diagnostic.log"))
args=parser.parse_args()
args.log.parent.mkdir(parents=True,exist_ok=True)
deadline=time.monotonic()+args.seconds
connection=None
with args.log.open("ab") as log:
    while time.monotonic()<deadline:
        try:
            if connection is None:
                # pyserial's modem-control initialization resets native ESP32-C3
                # USB/JTAG on every reopen. Observe bytes without touching DTR/RTS.
                connection=os.open(args.port,os.O_RDONLY|os.O_NOCTTY|os.O_NONBLOCK)
                attrs=termios.tcgetattr(connection)
                attrs[0]=0;attrs[1]=0;attrs[3]=0
                attrs[2]=(attrs[2]|termios.CLOCAL|termios.CREAD)&~termios.HUPCL
                attrs[6][termios.VMIN]=0;attrs[6][termios.VTIME]=0
                termios.tcsetattr(connection,termios.TCSANOW,attrs)
            if not select.select([connection],[],[],0.2)[0]: continue
            data=os.read(connection,4096)
            if data:
                log.write(data);log.flush()
                print(data.decode(errors="replace"),end="",flush=True)
            else:
                os.close(connection);connection=None;time.sleep(0.2)
        except (OSError,termios.error):
            if connection is not None:
                try: os.close(connection)
                except OSError: pass
            connection=None
            time.sleep(0.2)
    if connection is not None: os.close(connection)
