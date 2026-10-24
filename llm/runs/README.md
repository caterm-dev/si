# Local experiment outputs

Adapters and explicitly requested aggregate evaluation reports belong here and
are ignored by Git. Training writes weights/configuration through MLX LM;
inference prints candidates only to stdout and does not save requests or raw
model responses. Evaluation reports contain counts and timings, not input,
context or candidate text. Delete unwanted runs manually. There is no automatic
upload, expiry, telemetry integration or connection to SI's private archives.
