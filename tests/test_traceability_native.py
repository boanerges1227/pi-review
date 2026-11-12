"""Opt-in native SDK/Production verification, using a disposable loopback-only test instance."""
import json
import os
import re
import subprocess
import unittest
from concurrent.futures import ThreadPoolExecutor

CONTAINER = os.environ.get('PI_TRACE_CONTAINER', '')

@unittest.skipUnless(CONTAINER, 'Requires an isolated pi-689-* test container')
class NativeTrace(unittest.TestCase):
    def iris(self, code):
        if not re.fullmatch(r'pi-689-[A-Za-z0-9-]+', CONTAINER):
            raise RuntimeError('ISOLATED_CONTAINER_REQUIRED')
        result = subprocess.run(['docker','exec','-i',CONTAINER,'iris','session','IRIS','-U','USER'],
            input='try { '+ ' '.join(code.splitlines())+' write !,"NATIVE_OK",! } catch ex { write !,"NATIVE_FAILED ",ex.DisplayString(),! }\nhalt\n',
            text=True,capture_output=True,timeout=90)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('NATIVE_OK',result.stdout.splitlines(),result.stdout)
        self.assertNotIn('NATIVE_FAILED',result.stdout)
        return result.stdout

    def run_case(self, model='fixture-success'):
        code='''set sc=##class(Ens.Director).CreateBusinessService("InvestigationTrace",.service)
set request=##class(PI.Trace.RunRequest).%New(),request.CaseId="'''+model+'''",request.RunId=$increment(^PITraceFixtureSeq)
set sc=service.ProcessInput(request,.reply)
if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
write "RESULT=",{"traceId":(reply.TraceId),"sessionId":(reply.NativeSessionId)}.%ToJSON(),!
'''
        out=self.iris(code)
        data=json.loads(next(s[7:] for s in out.splitlines() if s.startswith('RESULT=')))
        self.assertRegex(data['traceId'],r'^[A-Fa-f0-9-]+$')
        code='''set rows=[],rs=##class(%SQL.Statement).%ExecDirect(,"SELECT * FROM PI_Trace.Event WHERE TraceId='''+"'"+data['traceId']+"'"+''' ORDER BY Sequence")
while rs.%Next() { set row={} for i=1:1:rs.%GetMetadata().columnCount { set name=rs.%GetMetadata().columns.GetAt(i).colName do row.%Set(name,rs.%Get(name)) } do rows.%Push(row) }
write "ROWS=",rows.%ToJSON(),!
'''
        out=self.iris(code)
        return data,json.loads(next(s[5:] for s in out.splitlines() if s.startswith('ROWS=')))

    def test_real_sdk_tool_loop_and_native_headers(self):
        data,rows=self.run_case()
        self.assertEqual(sum(r['Kind']=='model.request' for r in rows),2)
        responses=[r for r in rows if r['Kind']=='model.response']
        self.assertEqual(len(responses),2)
        self.assertEqual(sum(int(r['InputTokens']) for r in responses),52)
        self.assertEqual(sum(int(r['OutputTokens']) for r in responses),20)
        tools=[r for r in rows if r['Kind']=='tool.execution']
        self.assertEqual({r['ToolName'] for r in tools},{'get_case_summary','search_governance_rules'})
        self.assertTrue(all(r['ParentSpanId']=='http-1' for r in tools))
        self.assertEqual({str(r['NativeSessionId']) for r in rows},{str(data['sessionId'])})
        self.assertTrue(all(r['TraceMode']=='synthetic' for r in rows))
        out=self.iris('set rs=##class(%SQL.Statement).%ExecDirect(,"SELECT COUNT(*) AS N FROM Ens.MessageHeader WHERE SessionId='+str(data['sessionId'])+' AND SourceConfigName=\'InvestigationWorker\' AND MessageBodyClassName=\'PI.Trace.Event\'") do rs.%Next() write "COUNT=",rs.%Get("N"),!')
        self.assertIn('COUNT='+str(len(rows)),out)
        for private in ['FIXTURE_SECRET_KEY_MARKER','FIXTURE_SECRET_TOOL_CONTENT','FIXTURE_SECRET_GOVERNANCE_CONTENT','FIXTURE_SECRET_PROMPT_CONTENT','FIXTURE_SECRET_PROVIDER_ERROR']:
            self.assertNotIn(private,json.dumps(rows))

    def test_failure_and_unknown_usage(self):
        _,rows=self.run_case('fixture-failure')
        self.assertEqual(rows[-1]['Status'],'FAILED')
        self.assertTrue(any(int(r['HttpStatus'] or 0)==400 for r in rows if r['Kind']=='model.response'))
        self.assertFalse(any(r['Kind']=='tool.execution' for r in rows))
        _,rows=self.run_case('fixture-unknown')
        self.assertEqual(rows[-1]['Status'],'SUCCEEDED')
        self.assertTrue(all(int(r['UsageKnown'])==0 and r['InputTokens']=='' and int(r['CostKnown'])==0 for r in rows if r['Kind'] in ['model.response','sdk.end']))

    def test_multiple_sdk_phases_keep_tool_ids_unique(self):
        _,rows=self.run_case('fixture-repeat')
        tools=[r for r in rows if r['Kind']=='tool.execution']
        self.assertEqual(len(tools),4)
        self.assertEqual(len({r['SpanId'] for r in tools}),4)
        self.assertEqual([r['ParentSpanId'] for r in tools],['http-1','http-1','http-3','http-3'])

    def test_concurrent_sessions_are_isolated(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda _: self.run_case(),range(2)))
        self.assertNotEqual(results[0][0]['traceId'],results[1][0]['traceId'])
        self.assertNotEqual(results[0][0]['sessionId'],results[1][0]['sessionId'])
        for data,rows in results:
            self.assertEqual({r['TraceId'] for r in rows},{data['traceId']})
            self.assertEqual({str(r['NativeSessionId']) for r in rows},{str(data['sessionId'])})

if __name__=='__main__': unittest.main()
