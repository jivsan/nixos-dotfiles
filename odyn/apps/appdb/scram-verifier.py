# scram-verifier.py <role> <password-file> <connection-limit> [alter]
# prints a CREATE (or ALTER) ROLE with a SCRAM-SHA-256 verifier. run it on the host that keeps the
# password and pipe only its output into psql on yggdrasil: the password itself never leaves its host.
#   ssh <host> 'sudo nix shell nixpkgs#python3 -c python3 -I - <role> /var/lib/secrets/<role>-db-password <limit>' \
#     < scram-verifier.py | <psql as postgres on appdb> -f -
import base64, hashlib, hmac, os, re, sys

role, pwfile, limit = sys.argv[1], sys.argv[2], int(sys.argv[3])
assert re.fullmatch(r"[a-z][a-z0-9_]*", role), "role: lowercase letters, digits, _"
pw = open(pwfile, "rb").read().strip()
salt, rounds = os.urandom(16), 4096
salted = hashlib.pbkdf2_hmac("sha256", pw, salt, rounds)
client_key = hmac.new(salted, b"Client Key", "sha256").digest()
server_key = hmac.new(salted, b"Server Key", "sha256").digest()
b64 = lambda b: base64.b64encode(b).decode()
verifier = f"SCRAM-SHA-256${rounds}:{b64(salt)}${b64(hashlib.sha256(client_key).digest())}:{b64(server_key)}"
# a failing statement must not end up in the server log with the verifier in it
print("SET log_min_error_statement = 'panic'; SET log_statement = 'none';")
if len(sys.argv) > 4 and sys.argv[4] == "alter":
    print(f"ALTER ROLE {role} PASSWORD '{verifier}';")
else:
    print(f"CREATE ROLE {role} LOGIN CONNECTION LIMIT {limit} PASSWORD '{verifier}';")
