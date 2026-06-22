# migration-test: a tiny two-role workload used to ride the full pipeline
# (CI build -> Docker Hub -> ArgoCD -> webhook/Kueue/scheduler -> migration).
# busybox gives us /bin/sh (needed: the orchestrator execs mkdir/touch in the
# carried-over container, so the image must NOT be distroless).
FROM busybox:1.36
COPY run.sh /run.sh
ENTRYPOINT ["sh", "/run.sh"]
