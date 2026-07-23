# Mosquitto Standalone: stock Mosquitto instead of the HA add-on fork
# (motivation in config.yaml / docs). Base image is the official Eclipse
# image, pinned to exactly the version the official add-on ships (2.1.2) —
# the cutover then is a pure auth-plugin swap (go-auth out,
# builtin-security in), not a broker version jump. The Supervisor builds
# this image LOCALLY on the host (local add-on, no registry push needed).
FROM eclipse-mosquitto:2.1.2-alpine

# jq: run.sh reads the add-on options from /data/options.json (logins,
# migration_bridge). The container needs no other tooling.
RUN apk add --no-cache jq

COPY run.sh /run.sh
RUN chmod 755 /run.sh

# Our own startup path instead of the image entrypoint: run.sh generates
# mosquitto.conf + the password file from the options and execs mosquitto.
ENTRYPOINT []
CMD ["/run.sh"]
