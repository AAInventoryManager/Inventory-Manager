<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Inventory Manager</title>
  <!-- other head elements -->
</head>
<body>
  <!-- body content, including your main script -->
  <script>
    // ... existing main application script code ...

    async function deleteRow(id){
      if(SB.ready){
        await SB.client.from('items').delete().eq('id', id);
      } else {
        // local mode fallback
        const i = state.items.findIndex(x=>x.id===id);
        if(i>-1) state.items.splice(i,1);
        setUpdated(); save();
      }
      refreshNow();
    }

    async function deleteSelected(){
      const ids = getCheckedIds();
      if(!ids.length) return;
      if(SB.ready){
        await SB.client.from('items').delete().in('id', ids);
      } else {
        for(const id of ids){
          const i = state.items.findIndex(x=>x.id===id);
          if(i>-1) state.items.splice(i,1);
        }
        setUpdated(); save();
      }
      refreshNow();
    }

    function refreshNow(){ window.location.reload(); }

    async function sbAddItem(name, desc, qty){
      const id = crypto.randomUUID();
      const payload = [{ id, name: String(name||'').trim(), description: String(desc||''), qty: toInt(qty,0) }];
      const { error } = await SB.client.from('items').insert(payload);
      if(error){ throw error; }
      refreshNow();
    }

    async function sbUpdateFields(id, fields){
      const clean = {};
      if('name' in fields) clean.name = String(fields.name||'');
      if('desc' in fields) clean.description = String(fields.desc||'');
      if('qty'  in fields) clean.qty  = toInt(fields.qty,0);
      if(Object.keys(clean).length===0) return;
      const { error } = await SB.client.from('items').update(clean).eq('id', id);
      if(error){ throw error; }
      refreshNow();
    }

    async function sbUpsertMany(rows){
      const { data: existing, error: selErr } = await SB.client
        .from('items')
        .select('id,name,description,qty');
      if (selErr) throw selErr;

      const idx = new Map((existing||[]).map(it => [toKey(it.name), it]));
      const toInsert = [];
      const toUpdate = [];

      for (const r of rows){
        const k = toKey(r.name); if (!k) continue;
        const ex = idx.get(k);
        const name = String(r.name||'').trim();
        const description = String(r.desc||'').trim();
        const qty = toInt(r.qty,0);

        if (!ex){
          toInsert.push({ name, description, qty });
        } else {
          toUpdate.push({ id: ex.id, name, description: (description || ex.description || ''), qty });
        }
      }

      if (toInsert.length){
        const { error: insErr } = await SB.client.from('items').insert(toInsert);
        if (insErr) throw insErr;
      }
      if (toUpdate.length){
        const size = 500;
        for (let i=0;i<toUpdate.length;i+=size){
          const chunk = toUpdate.slice(i, i+size);
          const { error: upErr } = await SB.client.from('items').upsert(chunk, { onConflict: 'id' });
          if (upErr) throw upErr;
        }
      }
      refreshNow();
    }

    $('btnPasteApply').addEventListener('click', async ()=>{
      const text=$('pasteArea').value||''; if(!text.trim()){ toast('Nothing to import','warn'); return; }
      const rows=parseDelimited(text); const items=rowsToItems(rows);
      if(!items.length){ toast('Could not detect headers or rows','warn'); return; }
      try{
        if(SB.ready){ await sbUpsertMany(items); }
        else{
          const res=mergeItems(items, 'set'); // local fallback
          toast(`Pasted ${res.total} row(s): ${res.added} added, ${res.updated} updated`);
          setUpdated(); save();
          refreshNow();
        }
      }catch(err){ toast(err.message||'Import failed','warn'); }
    });

    $('fileBulk').addEventListener('change', async ev => {
      const f=ev.target.files[0]; if(!f) return;
      try{
        const items=await parseFile(f);
        if(!items.length) { toast('No rows found in file','warn'); return; }
        if(SB.ready){ await sbUpsertMany(items); }
        else{
          const res=mergeItems(items, 'set');
          toast(`Imported ${res.total} row(s): ${res.added} added, ${res.updated} updated`);
          setUpdated(); save();
          refreshNow();
        }
      }catch(err){ toast(err.message||'Import failed','warn'); }
      finally{ ev.target.value=''; }
    });

    $('btnAdd').addEventListener('click', async ()=>{
      const nm=($('newName').value||'').trim();
      const ds=($('newDesc').value||'').trim();
      const q=$('newQty').value||'0';
      if(!nm){ toast('Name required','warn'); return; }
      try{
        if(SB.ready){ await sbAddItem(nm, ds, q); }
        else{
          addItem(nm, ds, q); setUpdated(); save(); refreshNow();
        }
      }catch(e){ toast(e.message||'Add failed','warn'); }
    });

    // If you have an inline delete handler like onRowDelete(it), ensure it calls deleteRow or does:
    // async function onRowDelete(it) {
    //   await SB.client.from('items').delete().eq('id', it.id);
    //   refreshNow();
    // }

    // ... rest of your main script ...
  </script>
</body>
</html>
