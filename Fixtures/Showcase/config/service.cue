package preview

// At least one replica must run.
service: {
	name: "glimt"
	replicas: int & >=1
	enabled: true
}
