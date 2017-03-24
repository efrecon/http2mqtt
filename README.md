# http2mqtt

This program implements a simplistic application server that will bridge
web-applications to MQTT servers. In its simplest form, the program will forward
any data that is posted to the web server that it implements to a remote MQTT
server, using the HTTP path as the topic when publishing. Command-line arguments
allow to slightly modify the path when transforming it into a topic. In
addition, this program can implement a number of plugins, plugins that will be
able to transform the data before it is sent to the remote MQTT server.

## Command-Line Options

The program only accepts single-dash led full options on the command-line.
The complete list of recognised options can be fonud below:

- `-host` is the host name or IP address of the remote MQTT server to establish
  connection to. The default is to attempt connection to `localhost`.
  
- `-port` is the port number of the MQTT server, which defaults to the
  unencrypted MQTT official port of `1883`.
  
- `-user` is the username to authenticate with at the server. The default is an
  empty string, which means that no authentication will be attempted.
  
- `-password` is the password to use when authenticating.

- `-keepalive` is the number of seconds between the "pings" messages that are
  sent by the client to ensure that connection to the MQTT is kept alive at all
  times.
  
- `-retransmit` is the number of milliseconds between retransmissions, whenever
  these are necessary.
  
- `-qos` is the default QoS level to use when sending data to the server. This
  can be overriden when data is transformed and sent from plugins.
  
- `-retain` is the default value of the retain flag (a boolean) when sending
  data to the server. This can be overriden when data is transformed through
  plugins.
  
- `-omit` is a string that, if it exist, will be omitted from the beginning of
  the topic before publishing to the MQTT server.
  
- `-prepend` is a string that will be appended to the beginning of the topic
  before publishing to the MQTT server.

- `-append` is a string that will be appended to the end of the topic before
  publishing to the MQTT server.

- `-http` is a list of HTTP serving specifications, separated by white spaces.
  In its simplest form, a specification is just an integer, a port onto which
  the program will serve HTTP connections. Future extensions will allow to
  listen to HTTPS connections, for example.
  
- `-exts` is a whitespace separated list of directory specifications where to
  look for plugins.
  
- `-routes` is an even long list of routes where the first item is a pattern
  matching the incoming HTTP path and the second item a specification for how to
  transform data (see below).
  
All strings removed or appended through the `-omit`, `-prepend` and `-append`
options will have effect at all-time, including when sent from the plugins. It
is however possible to skip this behaviour by passing the option `-override on`
to the internal command `mqtt` available to plugin code for reaching out to the
server.

Through its `-routes` command-line option, you will be able to bind procedures
to a set of incoming URL paths. Both the posted data and the path are always
passed as arguments to the procedures and these will be able to both transform
data and path, for then sending to the relevant MQTT topics in their
transformed form. You will also be able to pass arguments to those procedures in
order to refine what they should perform or which topic they should send to, for
example. Data transformation occuring in plugins will be executed within safe
Tcl interpreters, which guarantees maximum flexibility when it comes to
transformation capabilities while guaranteeing security through encapsulation of
all IO and system commands.

All `tcl` files implementing the plugins should be placed in the directories
that is pointed at by the `-exts` option. Binding between URL paths and
procedures occurs through the `-routes` option. For example, starting the
program with `-routes "* myproc@myplugin.tcl"` will arrange for all URL paths
matching `*` (glob-style matching, e.g. all paths in this case) to be routed
towards the procedure `myproc` that can be found in the file `myplugin.tcl`.
Whenever an HTTP client performs a POST, the procedure will be called with two
arguments:

1. The full path that was requested by the client (since it matched
   `*`).

2. The data that the client sent as part of the `POST` command.

The procedure `myproc` is then free to perform any kind of operations
it deems necessary on both the data and the path.  Once all
transformation has succeeded, it can send the data using the `mqtt`
command.  That command is automatically bound to the remote server and
it could look similar to the following pseudo code:

    mqtt $path $data

To pass arguments to the procedure, you can separate them with
`!`-signs after the name of the procedure.  These arguments will be
blindly passed after the requested URL and the data to the procedure
when it is executed.  So, for example, if your route contained a
plugin specification similar to `myproc!onearg!3@myplugin.tcl`,
procedure `myproc` in `myplugin.tcl` would be called with four
arguments everytime a topic matches, i.e. the URL that was requested,
the content of the POST and `onearg` and `3` as arguments.  Spaces are
allowed in arguments, as long as you specify quotes (or curly-braces)
around the procedure call construct.
