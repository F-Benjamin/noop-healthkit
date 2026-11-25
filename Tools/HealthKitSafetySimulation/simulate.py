#!/usr/bin/env python3
"""Development-only SQLite growth measurement for NOOP's 1 Hz HR + canonical export queue."""
import argparse, json, os, sqlite3, tempfile, time
p=argparse.ArgumentParser(); p.add_argument('--days',type=int,default=30); p.add_argument('--output')
a=p.parse_args(); path=a.output or tempfile.mktemp(prefix='noop-health-',suffix='.sqlite')
seconds=a.days*86400; db=sqlite3.connect(path); db.execute('PRAGMA journal_mode=WAL'); db.execute('PRAGMA synchronous=OFF')
db.executescript('''
CREATE TABLE hrSample(deviceId TEXT NOT NULL, ts INTEGER NOT NULL, bpm INTEGER NOT NULL, PRIMARY KEY(deviceId,ts));
CREATE TABLE healthMeasurement(id TEXT PRIMARY KEY, metric TEXT NOT NULL, startTs REAL NOT NULL, endTs REAL NOT NULL, value REAL, deviceId TEXT NOT NULL, source TEXT NOT NULL, quality TEXT NOT NULL, sourceIdentifier TEXT NOT NULL, rateContext TEXT NOT NULL, healthKitStatus TEXT NOT NULL);
CREATE INDEX healthMeasurement_pending ON healthMeasurement(deviceId,metric,healthKitStatus,startTs);
''')
start=1700000000; batch=10000; t0=time.time()
for off in range(0,seconds,batch):
 n=min(batch,seconds-off)
 hrs=[('strap',start+off+i,55+(i%50)) for i in range(n)]
 can=[(f'whoop:strap:boot-1:hr:{off+i}','heartRate',start+off+i,start+off+i,55+(i%50),'strap','measuredDevice','valid','whoop-decoded-hr-v1','historicalBackfill','written' if (off+i)%60==0 else 'suppressedByProjectionPolicy') for i in range(n)]
 db.executemany('INSERT INTO hrSample VALUES(?,?,?)',hrs)
 db.executemany('INSERT INTO healthMeasurement VALUES(?,?,?,?,?,?,?,?,?,?,?)',can)
 db.commit()
db.execute('PRAGMA wal_checkpoint(TRUNCATE)'); pages=db.execute('PRAGMA page_count').fetchone()[0]; free=db.execute('PRAGMA freelist_count').fetchone()[0]; size=db.execute('PRAGMA page_size').fetchone()[0]
rows={t:db.execute(f'SELECT COUNT(*) FROM {t}').fetchone()[0] for t in ('hrSample','healthMeasurement')}; db.close()
result={'days':a.days,'elapsedSeconds':round(time.time()-t0,2),'rows':rows,'pageCount':pages,'freelistCount':free,'pageSize':size,'databaseBytes':os.path.getsize(path),'walBytes':os.path.getsize(path+'-wal') if os.path.exists(path+'-wal') else 0,'projectedHealthKitSamples':(seconds+59)//60,'projectedOneYearBytes':round(os.path.getsize(path)*365/a.days)}
print(json.dumps(result,indent=2));
if not a.output:
 os.unlink(path)
