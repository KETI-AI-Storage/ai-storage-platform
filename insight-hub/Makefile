# Regenerate Go protobuf stubs (requires protoc, protoc-gen-go, protoc-gen-go-grpc on PATH)
.PHONY: proto
proto:
	PATH="$$(go env GOPATH)/bin:$$PATH" protoc \
		--go_out=. --go_opt=module=insight-hub \
		--go-grpc_out=. --go-grpc_opt=module=insight-hub \
		-I proto proto/hub.proto

.PHONY: build
build:
	CGO_ENABLED=0 go build -o bin/insight-hub ./cmd/main.go
