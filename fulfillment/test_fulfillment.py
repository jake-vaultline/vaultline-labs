import json, tempfile, unittest
from pathlib import Path
from ingest_fulfillment import fulfill, verify, FulfillmentError

HERE=Path(__file__).parent
class FulfillmentTests(unittest.TestCase):
  def test_package_and_tamper_detection(self):
    with tempfile.TemporaryDirectory() as td:
      result=fulfill(HERE/"example-request.json",td)
      self.assertEqual(result["state"],"release-bound"); self.assertEqual(verify(td)["state"],"verified")
      (Path(td)/"GETTING-STARTED.md").write_text("changed")
      with self.assertRaises(FulfillmentError): verify(td)
  def test_ambiguity_stops_before_configuration(self):
    with tempfile.TemporaryDirectory() as td:
      request=json.loads((HERE/"example-request.json").read_text()); request["openQuestions"]=["Confirm media landing"]
      p=Path(td)/"request.json"; p.write_text(json.dumps(request))
      self.assertEqual(fulfill(p,Path(td)/"out")["state"],"clarification")
  def test_invalid_path_and_token_fail_closed(self):
    for mutation in ("path","token"):
      with tempfile.TemporaryDirectory() as td:
        r=json.loads((HERE/"example-request.json").read_text())
        if mutation=="path": r["resolved"]["workflows"][0]["folders"][0]="../escape"
        else: r["resolved"]["workflows"][0]["jobNameTemplate"]="{invented}"
        p=Path(td)/"r.json"; p.write_text(json.dumps(r))
        with self.assertRaises(FulfillmentError): fulfill(p,Path(td)/"out")
if __name__=="__main__": unittest.main()
