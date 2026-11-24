FROM alpine:3.20
WORKDIR /app
COPY . .
RUN echo "build complete"
CMD ["/bin/sh"]
