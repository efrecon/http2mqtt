# Make sure we can replace the original mqtt command.
rename ::mqtt ::__mqtt_orig

# ::mqtt -- Shortcut into mqtt command
#
#       This procedure bridges the !-based arguments to procedure separation
#       with the internal mqtt command that is given to all slave interpreters.
#       The procedure can be used, in combination with routes, to override QoS
#       or retain parameters.
#
# Arguments:
#	topic	MQTT topic to send to
#	data	Data to be sent to topic
#	qos	QoS level
#	retain	Boolean value of retain flag.
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc mqtt { topic hdrs data {qos 1} {retain 0} } {
    ::__mqtt_orig $topic $data -qos $qos -retain $retain
}