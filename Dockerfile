FROM golang:1.25 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/docker-secrets-1password ./cmd/docker-secrets-1password

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/docker-secrets-1password /usr/local/bin/docker-secrets-1password
USER nonroot:nonroot
ENTRYPOINT ["/usr/local/bin/docker-secrets-1password"]
