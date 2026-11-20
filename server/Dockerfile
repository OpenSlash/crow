FROM golang:1.24-bookworm AS build

WORKDIR /src
COPY server/go.mod server/go.sum* ./server/
WORKDIR /src/server
RUN go mod download

WORKDIR /src
COPY server ./server
WORKDIR /src/server
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/crow-cloud ./cmd/crow-cloud

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/crow-cloud /crow-cloud
USER nonroot:nonroot
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/crow-cloud"]
