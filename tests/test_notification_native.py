"""Real IRIS Production to loopback synthetic HIS; no model or hospital account."""
import concurrent.futures
import json
import os
import re
import subprocess
import time
import unittest
import uuid

CONTAINER = os.environ.get('PI_NOTIFICATION_CONTAINER', '')


@unittest.skipUnless(CONTAINER, 'Run scripts/notification-smoke.sh for isolated native verification')
class NativeNotifications(unittest.TestCase):
    def iris(self, code):
        """Run a guarded command in the disposable instance and require an explicit marker."""
        if not re.fullmatch(r'pi-notify-[A-Za-z0-9-]+', CONTAINER):
            raise ValueError('ISOLATED_CONTAINER_REQUIRED')
        result = subprocess.run(['docker', 'exec', '-i', CONTAINER, 'iris', 'session', 'IRIS', '-U', 'USER'],
                                input='try { ' + ' '.join(code.splitlines()) +
                                ' write !,"NOTIFY_NATIVE_OK",! } catch ex { write !,"NOTIFY_NATIVE_FAILED ",ex.DisplayString(),! }\nhalt\n',
                                text=True, capture_output=True, timeout=45)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('NOTIFY_NATIVE_OK', result.stdout.splitlines(), result.stdout)
        self.assertNotIn('NOTIFY_NATIVE_FAILED', result.stdout)
        for line in result.stdout.splitlines():
            if line.startswith('RESULT='):
                return json.loads(line[7:])
        return None

    def his(self, path, data=None):
        """Reach only the receiver inside the network-none container."""
        code = ('import json,urllib.request; data=' + repr(json.dumps(data).encode() if data is not None else None) +
                '; req=urllib.request.Request(' + repr('http://127.0.0.1:18894' + path) +
                ',data=data,headers={"Content-Type":"application/json"}); print(urllib.request.urlopen(req,timeout=3).read().decode())')
        result = subprocess.run(['docker', 'exec', CONTAINER, 'python3', '-c', code],
                                text=True, capture_output=True, timeout=10, check=True)
        return json.loads(result.stdout)

    def create(self, mode='normal', action='LINK'):
        """Generate a real review transaction with synthetic conflict records."""
        patient = 'notify-' + uuid.uuid4().hex
        self.his('/__test/control', {'patient': patient, 'mode': mode})
        data = self.iris('''
set a=##class(PI.Tests).Input("EMR","base-'''+patient+'''"),a.identifier="SYN-'''+patient+'''",a.name="'''+patient+''' Base",a.phone="'''+patient+'''"
set base=##class(PI.Store).Ingest(a),b=##class(PI.Tests).Input("HIS","'''+patient+'''"),b.identifier=a.identifier,b.name="'''+patient+''' Changed",b.phone=a.phone
set incoming=##class(PI.Store).Ingest(b),c=##class(PI.Store).Case(incoming.caseId)
set reviewed=##class(PI.Review).Decide(c.id,c.version,"'''+action+'''","r"_base.recordId,"Synthetic callback test")
set id="n"_^PIData($namespace,"seq","notification")
write "RESULT=",{"id":(id),"caseId":(c.id),"version":(reviewed.version),"masterId":(reviewed.review.newMasterId)}.%ToJSON(),!
''')
        data['patient'] = patient
        return data

    def notification(self, notification_id):
        return self.iris('write "RESULT=",^PIData($namespace,"notification","'+notification_id+'"),!')

    def wait(self, notification_id, status='SENT', timeout=16):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = self.notification(notification_id)
            if value['status'] == status:
                return value
            time.sleep(.3)
        self.fail('Notification did not reach '+status+': '+json.dumps(value))

    def test_01_custom_adapter_is_installed(self):
        result = self.iris('write "RESULT=",{"installed":(##class(%Dictionary.CompiledClass).%ExistsId("PI.Adapter.IdentityResultOutbound"))}.%ToJSON(),!')
        self.assertTrue(result['installed'], 'Custom Outbound Adapter is missing')

    def test_review_is_sent_with_matching_receipt_and_native_header(self):
        result = self.create()
        sent = self.wait(result['id'])
        self.assertFalse(sent['simulated'])
        self.assertEqual(sent['attempts'], 1)
        self.assertEqual(sent['receipt']['eventId'], sent['payload']['eventId'])
        self.assertEqual(sent['receipt']['status'], 'ACCEPTED')
        self.assertEqual(sent['payload']['masterId'], result['masterId'])
        self.assertEqual(sent['payload']['sourceSystem'], 'HIS')
        self.assertRegex(sent['payload']['occurredAt'], r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$')
        self.assertNotIn('name', sent['payload'])
        header = self.iris('set rs=##class(%SQL.Statement).%ExecDirect(,"SELECT COUNT(*) AS N FROM Ens.MessageHeader WHERE TargetConfigName=\'IdentityResultOutbound\' AND MessageBodyClassName=\'PI.Notification.Request\'") do rs.%Next() write "RESULT=",{"count":(rs.%Get("N"))}.%ToJSON(),!')
        self.assertGreater(header['count'], 0)

    def test_transient_failure_retries_same_event(self):
        result = self.create('fail-once')
        sent = self.wait(result['id'])
        self.assertEqual(sent['attempts'], 2)
        self.assertEqual(sent['receipt']['status'], 'ACCEPTED')

    def test_lost_receipt_retries_without_duplicate_effect(self):
        result = self.create('drop-once')
        sent = self.wait(result['id'])
        self.assertEqual(sent['attempts'], 2)
        self.assertEqual(sent['receipt']['status'], 'DUPLICATE')
        events = [e for e in self.his('/__test/state')['events'] if e['sourcePatientId'] == result['patient']]
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0], sent['payload'])

    def test_wrong_missing_and_malformed_receipts_are_not_success(self):
        for mode in ('wrong-ack-once', 'missing-receipt-once', 'malformed-once',
                     'invalid-status-once', 'http-error-once', 'oversized-once',
                     'wrong-id-type-once', 'long-receipt-once', 'empty-receipt-once'):
            with self.subTest(mode=mode):
                result = self.create(mode)
                sent = self.wait(result['id'])
                self.assertEqual(sent['attempts'], 2)
                self.assertEqual(sent['receipt']['status'], 'DUPLICATE')

    def test_exhaustion_preserves_review_and_manual_retry(self):
        result = self.create('always-fail')
        failed = self.wait(result['id'], 'FAILED')
        self.assertEqual(failed['attempts'], 3)
        reviewed = self.iris('write "RESULT=",##class(PI.Store).Case("'+result['caseId']+'").%ToJSON(),!')
        self.assertEqual(reviewed['status'], 'APPROVED')
        self.assertEqual(reviewed['version'], result['version'])
        time.sleep(2)
        self.assertEqual(self.notification(result['id'])['attempts'], 3)
        self.his('/__test/control', {'patient': result['patient'], 'mode': 'normal'})
        self.iris('do ##class(PI.Route).Notify("'+result['id']+'")')
        sent = self.wait(result['id'])
        self.assertEqual(sent['attempts'], 4)
        self.assertEqual(sent['payload'], failed['payload'])

    def test_undo_waits_for_result_and_delivers_correction(self):
        result = self.create('fail-once')
        correction = self.iris('set c=##class(PI.Review).Undo("'+result['caseId']+'",'+str(result['version'])+',"Synthetic undo callback") write "RESULT=",{"id":("n"_^PIData($namespace,"seq","notification"))}.%ToJSON(),!')
        self.wait(result['id'])
        sent = self.wait(correction['id'])
        self.assertEqual(sent['payload']['action'], 'UNDO')
        self.assertEqual(sent['payload']['masterId'], '')
        events = [e for e in self.his('/__test/state')['events'] if e['sourcePatientId'] == result['patient']]
        self.assertEqual([e['action'] for e in events], ['LINK', 'UNDO'])
        mappings = [m for m in self.his('/__test/state')['mappings'] if m['sourcePatientId'] == result['patient']]
        self.assertEqual(mappings[0]['masterId'], '')

    def test_separate_and_reject_snapshots(self):
        for action in ('SEPARATE', 'REJECT'):
            with self.subTest(action=action):
                result = self.create(action=action)
                sent = self.wait(result['id'])
                self.assertEqual(sent['payload']['action'], action)
                self.assertEqual(sent['payload']['masterId'], result['masterId'])

    def test_duplicate_local_work_does_not_resend_sent_event(self):
        result = self.create()
        sent = self.wait(result['id'])
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            list(pool.map(lambda _: self.iris('do ##class(PI.Route).Notify("'+result['id']+'")'), range(3)))
        time.sleep(2)
        self.assertEqual(self.notification(result['id'])['attempts'], sent['attempts'])

    def test_outbox_recovers_after_production_restart_and_expired_lease(self):
        self.iris('set sc=##class(Ens.Director).StopProduction(,1) if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }')
        try:
            result = self.create()
            pending = self.notification(result['id'])
            self.assertEqual(pending['status'], 'PENDING')
            self.assertEqual(pending['attempts'], 0)
            # Simulate interruption after claiming work but before its queue submission.
            claimed = self.iris('set ok=##class(PI.Notification.Outbox).Claim("'+result['id']+'") write "RESULT=",{"claimed":(ok)}.%ToJSON(),!')
            self.assertTrue(claimed['claimed'])
            again = self.iris('write "RESULT=",{"claimed":(##class(PI.Notification.Outbox).Claim("'+result['id']+'"))}.%ToJSON(),!')
            self.assertFalse(again['claimed'])
            self.iris('set n={}.%FromJSON(^PIData($namespace,"notification","'+result['id']+'")),n.nextAttemptAt=0 set ^PIData($namespace,"notification","'+result['id']+'")=n.%ToJSON()')
        finally:
            self.iris('set sc=##class(Ens.Director).StartProduction("PI.NotificationProduction") if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }')
        sent = self.wait(result['id'])
        self.assertEqual(sent['attempts'], 1)
        self.assertEqual(sent['payload'], pending['payload'])

    def test_outbox_is_rolled_back_with_mapping_transaction(self):
        result = self.create()
        self.wait(result['id'])
        state = self.iris('set before=^PIData($namespace,"seq","notification") tstart  set id=##class(PI.Review).Notification("'+result['caseId']+'","m-rollback","APPROVAL") trollback  write "RESULT=",{"exists":($data(^PIData($namespace,"notification",id))),"pending":($data(^PIData($namespace,"notificationPending",before+1)))}.%ToJSON(),!')
        self.assertFalse(state['exists'])
        self.assertFalse(state['pending'])

    def test_relay_cannot_send_uncommitted_review_event(self):
        result = self.create()
        self.wait(result['id'])
        self.iris('kill ^PINotificationFixtureReady')
        code = ('lock +^PIData($namespace,"lock"):3 tstart  '
                'set c=##class(PI.Store).Case("'+result['caseId']+'"),c.version=c.version+1 '
                'set ^PIData($namespace,"case",c.id)=c.%ToJSON() '
                'set id=##class(PI.Review).Notification(c.id,"m-rollback","APPROVAL"),^PINotificationFixtureReady=id '
                'hang 5 trollback  lock -^PIData($namespace,"lock")')
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            writer = pool.submit(self.iris, code)
            deadline = time.monotonic() + 3
            notification_id = ''
            while time.monotonic() < deadline:
                ready = self.iris('write "RESULT=",{"id":($get(^PINotificationFixtureReady))}.%ToJSON(),!')
                notification_id = ready['id']
                if notification_id:
                    break
                time.sleep(.05)
            self.assertTrue(notification_id, 'The held-open transaction did not start')
            time.sleep(1.5)
            held = self.notification(notification_id)
            self.assertEqual(held['status'], 'PENDING', 'Relay consumed an uncommitted review event')
            self.assertEqual(held['attempts'], 0)
            writer.result()
        events = self.his('/__test/state')['events']
        self.assertNotIn(held['payload']['eventId'], [event['eventId'] for event in events])

    def test_interrupted_final_attempt_cannot_exceed_retry_limit(self):
        result = self.create('always-fail')
        self.wait(result['id'], 'FAILED')
        self.his('/__test/control', {'patient': result['patient'], 'mode': 'normal'})
        # Reproduce a worker that persisted its final attempt but died before saving its outcome.
        self.iris('set n={}.%FromJSON(^PIData($namespace,"notification","'+result['id']+'")),n.status="QUEUED",n.nextAttemptAt=0 set ^PIData($namespace,"notification",n.id)=n.%ToJSON(),^PIData($namespace,"notificationPending",n.sequence)=n.id')
        recovered = self.wait(result['id'], 'FAILED')
        self.assertEqual(recovered['attempts'], 3, 'Recovery exceeded the configured retry budget')

    def test_manual_retry_rejects_an_uncommitted_caller_transaction(self):
        result = self.create('always-fail')
        self.wait(result['id'], 'FAILED')
        state = self.iris('set rejected=0 tstart  try { do ##class(PI.Route).Notify("'+result['id']+'") } catch ex { set rejected=(ex.Name="NOTIFICATION_RETRY_TRANSACTION_UNSUPPORTED") } trollback  write "RESULT=",{"rejected":(rejected)}.%ToJSON(),!')
        self.assertTrue(state['rejected'], 'A caller transaction can reopen work before commit')

    def test_parallel_duplicate_queue_entries_send_once(self):
        self.iris('set sc=##class(Ens.Director).StopProduction(,1)')
        try:
            result = self.create('slow-once')
            self.iris('set claimed=##class(PI.Notification.Outbox).Claim("'+result['id']+'")')
        finally:
            self.iris('set sc=##class(Ens.Director).StartProduction("PI.NotificationProduction") if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }')
        self.iris('set sc=##class(Ens.Director).CreateBusinessService("Intake",.service) if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) } for i=1:1:4 { set req=##class(PI.Notification.Request).%New(),req.NotificationId="'+result['id']+'" set sc=service.SendRequestAsync("IdentityResultOutbound",req) if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) } }')
        sent = self.wait(result['id'])
        time.sleep(1)
        self.assertEqual(sent['attempts'], 1)
        events = [e for e in self.his('/__test/state')['events'] if e['sourcePatientId'] == result['patient']]
        self.assertEqual(len(events), 1)

    def test_historical_simulated_rows_are_not_replayed(self):
        before = self.his('/__test/state')['attempts']
        self.iris('set id="historical-synthetic" set ^PIData($namespace,"notification",id)={"id":(id),"status":"FAILED","attempts":1,"simulated":true}.%ToJSON() do ##class(PI.Route).Notify(id)')
        time.sleep(1.2)
        row = self.notification('historical-synthetic')
        self.assertEqual(row['status'], 'FAILED')
        self.assertEqual(row['attempts'], 1)
        self.assertEqual(self.his('/__test/state')['attempts'], before)

    def test_main_production_callback_items_are_disabled(self):
        items = self.iris('set rows=[],rs=##class(%SQL.Statement).%ExecDirect(,"SELECT Name,Enabled FROM Ens_Config.Item WHERE Production=\'PI.Production\' AND Name IN (\'IdentityResultRelay\',\'IdentityResultOutbound\')") while rs.%Next() { do rows.%Push({"name":(rs.%Get("Name")),"enabled":(rs.%Get("Enabled"))}) } write "RESULT=",rows.%ToJSON(),!')
        self.assertEqual({item['name'] for item in items}, {'IdentityResultRelay', 'IdentityResultOutbound'})
        self.assertTrue(all(not item['enabled'] for item in items))

    def test_review_entry_points_cannot_publish_inside_a_caller_transaction(self):
        result = self.create()
        self.wait(result['id'])
        rejected = self.iris('set rejected=0 tstart  try { set c=##class(PI.Review).Undo("'+result['caseId']+'",'+str(result['version'])+',"Nested caller rollback") } catch ex { set rejected=(ex.Name="REVIEW_TRANSACTION_UNSUPPORTED") } trollback  write "RESULT=",{"rejected":(rejected)}.%ToJSON(),!')
        self.assertTrue(rejected['rejected'])
        opened = self.iris('set c=##class(PI.Review).Undo("'+result['caseId']+'",'+str(result['version'])+',"Synthetic reopen") write "RESULT=",{"version":(c.version),"id":("n"_^PIData($namespace,"seq","notification"))}.%ToJSON(),!')
        self.wait(opened['id'])
        rejected = self.iris('set rejected=0 tstart  try { set c=##class(PI.Review).Decide("'+result['caseId']+'",'+str(opened['version'])+',"SEPARATE","","Nested caller rollback") } catch ex { set rejected=(ex.Name="REVIEW_TRANSACTION_UNSUPPORTED") } trollback  write "RESULT=",{"rejected":(rejected)}.%ToJSON(),!')
        self.assertTrue(rejected['rejected'])


if __name__ == '__main__':
    unittest.main()
