# syntax=docker/dockerfile:1
FROM golang:1.25
WORKDIR /src
COPY ./main.go ./main.go
RUN CGO_ENABLED=0 GOOS=linux go build -o /bin/hello ./main.go

FROM scratch
COPY --from=0 /bin/hello /bin/hello
EXPOSE 8086
CMD ["/bin/hello"]