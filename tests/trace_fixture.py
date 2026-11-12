"""Local synthetic model fixture: no outbound network and no request-body logging."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json, os
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_POST(self):
  data=json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))))
  if data.get('model')=='fixture-failure':
   status=400;payload={'error':{'message':'FIXTURE_SECRET_PROVIDER_ERROR','type':'invalid_request_error'}}
  elif any(m.get('role')=='tool' for m in data.get('messages',[])[1+max((i for i,m in enumerate(data.get('messages',[])) if m.get('role')=='user'),default=-1):]):
   status=200;payload={'id':'fixture-response','object':'chat.completion','created':1,'model':data['model'],'choices':[{'index':0,'message':{'role':'assistant','content':json.dumps({'decision':'NEEDS_REVIEW','summary':'Synthetic human review required.','evidenceIds':['case-1','policy-1']})},'finish_reason':'stop'}],'usage':{'prompt_tokens':32,'completion_tokens':12,'total_tokens':44}}
  else:
   status=200;payload={'id':'fixture-tools','object':'chat.completion','created':1,'model':data['model'],'choices':[{'index':0,'message':{'role':'assistant','content':None,'tool_calls':[{'id':'case-call','type':'function','function':{'name':'get_case_summary','arguments':'{}'}},{'id':'policy-call','type':'function','function':{'name':'search_governance_rules','arguments':'{}'}}]},'finish_reason':'tool_calls'}],'usage':{'prompt_tokens':20,'completion_tokens':8,'total_tokens':28}}
  if data.get('model')=='fixture-unknown': payload.pop('usage',None)
  body=json.dumps(payload).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
ThreadingHTTPServer(('127.0.0.1',int(os.environ.get('TRACE_FIXTURE_PORT','18891'))),Handler).serve_forever()
