#!/bin/bash

# Install microk8s
sudo snap install microk8s --classic
sudo usermod -a -G microk8s $USER
sudo chown -R $USER ~/.kube
newgrp microk8s


# Enable GPU support
microk8s enable gpu

# Enable storage support
# See: https://microk8s.io/docs/addon-hostpath-storage
microk8s enable storage

# Configure kubectl
mkdir -p ~/.kube
microk8s config >> ~/.kube/config