import json
from os import walk
from os.path import join, isfile
import sys

summary = []

for (dirpath, dirnames, filenames) in walk("../participantes/"):
    for filename in filenames:
        entry = {}
        if (filename == "info.json"):
            info_file = join(dirpath, "info.json")
            with open(info_file) as f:
                try:
                    entry.update({
                        "info": json.loads(f.read())
                    })
                except Exception as ex:
                    entry.update({
                        "info": None
                    })

            partial_result_file = join(dirpath, "partial-results.json")
            errors_log_file = join(dirpath, "error.logs")
            entry.update({"erro_na_execucao": isfile(errors_log_file)})

            if (isfile(partial_result_file)):
                with open(partial_result_file) as f:
                    partial_results = f.read()
                    if (partial_results):
                        entry.update({
                            "resultado_partial": json.loads(partial_results)
                        })
            else:
                entry.update({
                    "resultado_partial": None
                })

        if (entry):
            summary.append(entry)

summary_file = sys.argv[1] if len(sys.argv) > 1 else "../previa-resultados+participantes-info.json"

with open(summary_file, 'w') as pf:
    pf.write(json.dumps(summary))
