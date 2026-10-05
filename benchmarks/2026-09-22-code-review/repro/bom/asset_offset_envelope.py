import struct,sys
def env(lane,kind,payload):
    return b"GOH2"+bytes([2,1,lane,kind])+struct.pack(">HQ",0,7)+bytes(range(16))+bytes(range(16,32))+struct.pack(">I",len(payload))+payload
h=bytes.fromhex("ab"*32)
req=env(3,0x33,h+b"\xff"*8)
slide="﻿gate".encode()
pres=env(2,0x20,struct.pack(">Q",1)+bytes(16)+b"\x01"+struct.pack(">Q",5)+struct.pack(">H",len(slide))+slide)
print(req.hex()); print(pres.hex())
