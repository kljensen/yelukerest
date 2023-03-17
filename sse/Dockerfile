FROM golang:alpine3.16 as builder
# install xz
# create a working directory
WORKDIR /go/src/app
# add source code
ADD . .
# build the source
RUN CGO_ENABLED=0 GOOS=linux go build -mod vendor -a -installsuffix cgo -o main 

# use scratch (base for a docker image)
FROM scratch
# set working directory
WORKDIR /root
# copy the binary from builder
COPY --from=builder /go/src/app/main .
# run the binary
CMD ["./main"]
