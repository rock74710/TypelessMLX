import json, sys, time
print(json.dumps({'status': 'ready'}), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    if request.get('action') == 'ping':
        continue
    mode = request.get('model')
    if mode == 'crash':
        sys.exit(4)
    if mode == 'delayed':
        time.sleep(0.4)
    result = {'id': request['id'], 'text': 'raw 12.5 text', 'error': None}
    print(json.dumps(result), flush=True)
    if mode == 'duplicate':
        print(json.dumps(result), flush=True)
