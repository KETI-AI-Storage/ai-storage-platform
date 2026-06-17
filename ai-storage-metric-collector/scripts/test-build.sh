registry="ketidevit2"
image_name="ai-storage-metric-collector"
version="v0.0.1"
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
project_root="$dir/.."

# build binary file
go build -o "$dir/../build/_output/bin/$image_name" -mod=vendor "$dir/../cmd/main.go"

# make image (Dockerfile must be in build/)
docker build -t "$image_name:$version" -f "$project_root/build/Dockerfile" "$project_root"

# add tag
docker tag "$image_name:$version" "$registry/$image_name:$version"

# login
docker login

# push image
docker push "$registry/$image_name:$version"