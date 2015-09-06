# OC-FTP
This is a small hobby project written for the Minecraft mod OpenComputers.
The goal is to provide a FTP server that can be run on an ingame computer,
accessible from the internet. Because OpenComputers limitaion on internet
functionality, a proxy must be used to listen on an open port.

## FTP Server
The main server logic is written in lua for OpenOS. While most of the basic
functionality is implemented, there is a lot left for it to be a standard
compliant FTP server. Testing has been done using the NppFTP plugin in
Notepad++ with default settings. Being able to write code for OpenComputers
in Notepad++ helps a lot, not least during refactoring.

## Proxy
The proxy is split into two parts, one is the proxy itself, written in C#,
and the other part is the OpenComputers library that is used by the FTP
server. The proxy is written as a general proxy, that is, it can be used for
any protocol, not just for FTP. However, it currently only allows for
incoming connections, that is, it can not connect to other servers. This may
get added in the future, but was not required in order to create an FTP
server with the limitation that clients must request a passive data
connection. It is also somewhat of a security concern: a proxy that can not
connect to other servers is less useful for general uses, and thus less
likely to be exploited.

## Security
It would be nice to add SSL/TLS to the FTP server, but running encryption
algorithms in lua would be less than optimal. There is a Data Card added
to OpenComputers that provide some encryption functions, but I have not
looked into it enough to know if it is usable, or worth the trouble. It is a
game after all.
