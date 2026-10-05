var d = java.nio.charset.StandardCharsets.UTF_8.newDecoder().onMalformedInput(java.nio.charset.CodingErrorAction.REPORT);
var s = d.decode(java.nio.ByteBuffer.wrap(new byte[]{(byte)0xEF,(byte)0xBB,(byte)0xBF,0x41})).toString();
System.out.println(s.length() + " " + Integer.toHexString(s.charAt(0)));
System.out.println(Integer.parseInt("-1",16) + " " + Integer.parseInt("+f",16));
/exit
