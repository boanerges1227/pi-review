"""A real final-ack gate must prevent the investigation completion key from becoming visible."""
import json, os, re, subprocess, unittest
C=os.environ.get('PI_TRACE_FULL_CONTAINER','')
@unittest.skipUnless(C,'Requires a disposable pi-689-* full application instance')
class Publication(unittest.TestCase):
 def iris(self, code, ns='PITEST'):
  if not re.fullmatch(r'pi-689-[A-Za-z0-9-]+',C):raise RuntimeError('ISOLATED_CONTAINER_REQUIRED')
  r=subprocess.run(['docker','exec','-i',C,'iris','session','IRIS','-U',ns],input='try { '+' '.join(code.splitlines())+' write !,"GATE_OK",! } catch ex { write !,"GATE_FAILED ",ex.DisplayString(),! }\nhalt\n',text=True,capture_output=True,timeout=90)
  self.assertEqual(r.returncode,0,r.stderr);self.assertIn('GATE_OK',r.stdout.splitlines(),r.stdout);self.assertNotIn('GATE_FAILED',r.stdout);return r.stdout
 def setUp(self):
  self.iris('do ##class(Ens.Director).StopProduction(5,1) set sc=$system.OBJ.Load("/workspace/tests/PI/TraceGatedSink.cls","ck") set sc=$system.OBJ.Load("/workspace/tests/PI/TraceGatedProduction.cls","ck") set sc=##class(Ens.Director).StartProduction("PI.TraceGatedProduction") if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) } kill ^PIModels($namespace,"active")')
 def tearDown(self):
  self.iris('do ##class(Ens.Director).StopProduction(5,1) set sc=##class(Ens.Director).StartProduction("PI.Production")')
 def check_gate(self,reject):
  out=self.iris('set seeded=##class(PI.Fixtures).Seed(),c=seeded.cases.%Get(0),run=620689+$increment(^PITraceGate("seq")),^PITraceGate(run,"block")=1,^PITraceGate(run,"reject")='+str(int(reject))+' job ##class(PI.Agent).Worker(c.id,run) for i=1:1:400 { quit:$get(^PITraceGate(run,"entered"))  hang 0.025 } write "BEFORE=",{"run":(run),"entered":(+$get(^PITraceGate(run,"entered"))),"published":($data(^PIData($namespace,"work",run))>0),"runPublished":($data(^PIData($namespace,"run",c.id,run))>0)}.%ToJSON(),!')
  before=json.loads(next(x[7:] for x in out.splitlines() if x.startswith('BEFORE=')))
  # Release even when the assertion will fail, so a red test does not leave a blocked native worker.
  out=self.iris('set run='+str(before['run'])+',^PITraceGate(run,"release")=1 for i=1:1:400 { quit:$data(^PIData($namespace,"work",run))  hang 0.025 } write "AFTER=",$get(^PIData($namespace,"work",run)),!')
  self.assertEqual(before['entered'],1)
  self.assertEqual(before['published'],False,'completion must remain private until final trace acknowledgement')
  self.assertEqual(before['runPublished'],False,'diagnostic run history must remain private too')
  after=json.loads(next(x[6:] for x in out.splitlines() if x.startswith('AFTER=')))
  if reject:self.assertEqual(after['error'],'TRACE_FAILED')
 def test_accepted_final_ack_publishes_after_acceptance(self):self.check_gate(False)
 def test_rejected_final_ack_never_publishes_success(self):self.check_gate(True)
if __name__=='__main__':unittest.main()
