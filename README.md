# http2mqtt

This program implements a simplistic application server that will bridge
web-applications to MQTT servers. In its simplest form, the program will forward
any data that is posted to the web server that it implements to a remote MQTT
server, using the HTTP path as the topic when publishing. Command-line arguments
allow to slightly modify the path when transforming it into a topic. In
addition, this program can implement a number of plugins, plugins that will be
able to transform the data before it is sent to the remote MQTT server.