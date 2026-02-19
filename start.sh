#!/bin/bash

# Build the image
podman build -t aws-cli .

# Run the container as root, mounting the current directory and AWS credentials
podman run --rm -it \
       --network host\
       --user root \
       --env-file env.txt\
       -v "$(pwd)":/workspace \
       -w /workspace \
       --entrypoint ""\
       -it aws-cli \
       /bin/bash
