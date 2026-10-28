Class PI.Fixtures Extends %RegisteredObject
{
/// Reload fixed synthetic cases without clearing existing work items or calling external models.
ClassMethod Seed() As %DynamicObject
{
    set base={"sourceSystem":"HIS","sourcePatientId":"DEMO-HIS-001","sourceVersion":1,"name":"Alce Chen","birthDate":"1985-05-06","sex":"F","identifier":"SYN-1001","phone":"TEST-PHONE-1","notes":"Synthetic: historical spelling"}
    set z=##class(PI.Store).Ingest(base)
    set base.sourceVersion=2,base.name="Alice Chen",base.notes="Synthetic: corrected spelling",z=##class(PI.Store).Ingest(base)
    set incoming=base.%FromJSON(base.%ToJSON()),incoming.sourceSystem="EMR",incoming.sourcePatientId="DEMO-EMR-001",incoming.sourceVersion=1,incoming.name="Alce Chen",incoming.notes="Synthetic: old spelling from EMR"
    set z=##class(PI.Store).Ingest(incoming)
    set conflict=base.%FromJSON(base.%ToJSON()),conflict.sourcePatientId="DEMO-HIS-002",conflict.sourceVersion=1,conflict.identifier="SYN-9999",conflict.notes="Synthetic: same name, different identifier"
    set z=##class(PI.Store).Ingest(conflict)
    set known={"sourceSystem":"HIS","sourcePatientId":"DEMO-HIS-003","sourceVersion":1,"name":"Mei Lin","birthDate":"1990-07-08","sex":"F","identifier":"SYN-2001","phone":"TEST-PHONE-2","notes":"Synthetic: complete source record"}
    set z=##class(PI.Store).Ingest(known)
    set missing=known.%FromJSON(known.%ToJSON()),missing.sourceSystem="CHECKUP",missing.sourcePatientId="DEMO-CHECKUP-003",missing.birthDate="",missing.identifier="",missing.notes="Synthetic: needs source enrichment"
    set z=##class(PI.Store).Ingest(missing)
    quit {"synthetic":true,"cases":(##class(PI.Store).List())}
}
}
