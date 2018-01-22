/*******************************************************************************
 * Bundle Remotes
 *
 * Created by Aquameta Labs, an open source company in Portland Oregon, USA.
 * Company: http://aquameta.com/
 * Project: http://blog.aquameta.com/
 ******************************************************************************/

begin;

set search_path=bundle;

/*******************************************************************************
*
*
* BUNDLE REMOTES
*
*
*******************************************************************************/

/*******************************************************************************
* bundle.has_bundle
* checks a remote to see if it also has a bundle with the same id installed
*******************************************************************************/

create or replace function bundle.remote_has_bundle(in _remote_id uuid, out has_bundle boolean)
as $$
declare
    local_bundle_id uuid;
    remote_endpoint_id uuid;
begin
    -- look up endpoint_id
    select into remote_endpoint_id e.id from endpoint.remote_endpoint e join bundle.remote r on r.endpoint_id = e.id where r.id = _remote_id;
    select into local_bundle_id r.bundle_id from endpoint.remote_endpoint e join bundle.remote r on r.endpoint_id = e.id where r.id = _remote_id;

    raise notice '########### remote has bundle: % % %', _remote_id, remote_endpoint_id, local_bundle_id;
    if _remote_id is null or remote_endpoint_id is null or local_bundle_id is null then 
        has_bundle := false; 
        return; 
    end if;

    -- 
    select into has_bundle (count(*) = 1)::boolean from (
        select 
            (json_array_elements((rc.response_text::json)->'result')->'row'->>'id') as id
            from endpoint.client_rows_select(
                    remote_endpoint_id,
                    meta.relation_id('bundle','bundle'),
                    ARRAY['id'],
                    ARRAY[local_bundle_id::text]
            ) rc
    ) has;
end;
$$ language plpgsql;





/*******************************************************************************
* bundle.remote_compare_commits
* diffs the set of local commits with the set of remote commits
*******************************************************************************/

create or replace function bundle.remote_compare_commits(in _remote_id uuid)
returns table(local_commit_id uuid, remote_commit_id uuid)
as $$
declare
    local_bundle_id uuid;
    remote_endpoint_id uuid;
begin
    select into local_bundle_id bundle_id from bundle.remote r where r.id = _remote_id;
    select into remote_endpoint_id e.id from endpoint.remote_endpoint e join bundle.remote r on r.endpoint_id = e.id where r.id = _remote_id;

    raise notice '########## bundle compare: % % %', _remote_id, local_bundle_id, remote_endpoint_id;

    return query
        with remote_commit as (
            select 
                (json_array_elements((rc.response_text::json)->'result')->'row'->>'id')::uuid as id
            from 
                endpoint.client_rows_select(
                    remote_endpoint_id,
                    meta.relation_id('bundle','commit'),
                    ARRAY['bundle_id'],
                    ARRAY[local_bundle_id::text]
            ) rc
        )
        select lc.id, rc.id
        from remote_commit rc
        full outer join bundle.commit lc on lc.id = rc.id
        where lc.bundle_id = local_bundle_id or lc.bundle_id is null;
end;
$$ language plpgsql;







/*******************************************************************************
* bundle.construct_bundle_diff
* fills a temporary table with the commits specified, but only including NEW blobs
*******************************************************************************/

create or replace function bundle.construct_bundle_diff(bundle_id uuid, new_commits uuid[], temp_table_name text, create_bundle boolean default false)
returns setof endpoint.join_graph_row as $$
declare
    new_commits_str text;
begin
    select into new_commits_str string_agg(q,',') from (
    select quote_literal(unnest(new_commits)) q) as quoted;
    raise notice '######## CONSTRUCTING BUNDLE DIFF FOR COMMITS %', new_commits_str;

    perform endpoint.construct_join_graph(
            temp_table_name,
            ('{ "schema_name": "bundle", "relation_name": "bundle", "label": "b", "pk_field": "id", "where_clause": "b.id = ''' || bundle_id::text || '''", "position": 1, "exclude": ' || (not create_bundle)::text || '}')::json,
            ('[
                {"schema_name": "bundle", "relation_name": "commit",           "label": "c",   "join_pk_field": "id", "join_local_field": "bundle_id",     "related_label": "b",   "related_field": "id",         "position": 6, "where_clause": "c.id in (' || new_commits_str || ')"},
                {"schema_name": "bundle", "relation_name": "rowset",           "label": "r",   "join_pk_field": "id", "join_local_field": "id",            "related_label": "c",   "related_field": "rowset_id",  "position": 2},
                {"schema_name": "bundle", "relation_name": "rowset_row",       "label": "rr",  "join_pk_field": "id", "join_local_field": "rowset_id",     "related_label": "r",   "related_field": "id",         "position": 3},
                {"schema_name": "bundle", "relation_name": "rowset_row_field", "label": "rrf", "join_pk_field": "id", "join_local_field": "rowset_row_id", "related_label": "rr",  "related_field": "id",         "position": 5},
                {"schema_name": "bundle", "relation_name": "blob",             "label": "blb", "join_pk_field": "hash", "join_local_field": "hash",          "related_label": "rrf", "related_field": "value_hash", "position": 4}
             ]')::json
        );

    return query execute format ('select label, row_id, row::jsonb, position, exclude from %I order by position', quote_ident(temp_table_name));

end;
$$ language plpgsql;




/*******************************************************************************
* bundle.push
* transfer to a remote repository any local commits not present in the remote
*
* 1. run compare_commits() to create new_commits array, commits that shall be pushed
* 2. construct_bundle_diff() to create a join_graph_row table containing new commit rows
* 3. serialize this table to json via join_graph_to_json()
* 4. ship the json via client_rows_insert to the remote's rows_insert method
* 5. the remote deserializes and inserts the rows
*******************************************************************************/

create or replace function bundle.remote_push(in remote_id uuid, in create_bundle boolean default false)
returns void -- table(_row_id meta.row_id)
as $$
declare
    new_commits uuid[];
    bundle_id uuid;
    result jsonb;
    endpoint_id uuid;
begin
    raise notice '################################### PUSH ##########################';
    select into bundle_id r.bundle_id from bundle.remote r where r.id = remote_id;
    select into endpoint_id e.id from bundle.remote r join endpoint.remote_endpoint e on r.endpoint_id = e.id where r.id = remote_id;

    -- 1. get the array of new remote commits
    select into new_commits array_agg(local_commit_id)
        from bundle.remote_compare_commits(remote_id)
        where remote_commit_id is null;
    raise notice 'NEW COMMITS: %', new_commits::text;

    -- 2. construct bundle diff
    perform bundle.construct_bundle_diff(bundle_id, new_commits, 'bundle_push_1234', create_bundle);

    -- 3. join_graph_to_json()
    select into result endpoint.join_graph_to_json('bundle_push_1234');

    -- raise notice 'PUUUUUUUUUSH result: %', result::text;

    -- http://hashrocket.com/blog/posts/faster-json-generation-with-postgresql
    perform endpoint.client_rows_insert (endpoint_id, result);
    -- from (select * from bundle_push_1234 order by position) as b;

    drop table bundle_push_1234;
end;
$$ language plpgsql;



/*******************************************************************************
* bundle.fetch
* download from remote repository any commits not present in the local repository
*******************************************************************************/

create or replace function bundle.remote_fetch(in remote_id uuid, create_bundle boolean default false)
returns void -- table(_row_id meta.row_id)
as $$
declare
    bundle_id uuid;
    endpoint_id uuid;
    new_commits uuid[];
    json_results jsonb;
begin
    raise notice '################################### FETCH ##########################';
    select into bundle_id r.bundle_id from bundle.remote r where r.id = remote_id;
    select into endpoint_id r.endpoint_id from bundle.remote r where r.id = remote_id;

    -- get the array of new remote commits
    select into new_commits array_agg(remote_commit_id)
        from bundle.remote_compare_commits(remote_id)
        where local_commit_id is null;

    raise notice 'NEW COMMITS: %', new_commits::text;

    -- create a join_graph on the remote via the construct_bundle_diff function
    select into json_results response_text::jsonb from endpoint.client_rows_select_function(
        endpoint_id,
        meta.function_id('bundle','construct_bundle_diff', ARRAY['bundle_id','new_commits','temp_table_name','create_bundle']),
        ARRAY[bundle_id::text, new_commits::text, 'bundle_diff_1234'::text, false::text]
    );
    -- raise notice '################# RESULTS: %', json_results;
    perform endpoint.rows_insert(endpoint.endpoint_response_to_joingraph(json_results)::json);

    -- drop table bundle_diff_1234;
end;
$$ language plpgsql;


/*******************************************************************************
*
*
* BUNDLE REMOTES -- postgres_fdw
*
* This version uses the postgres_fdw foreign data wrapper to mount remote
* databases via a normal postgresql connection.  It uses IMPORT FOREIGN SCHEMA
* to import the bundle schema, and then provides various comparison functions
* for push, pull and merge.
* 
*******************************************************************************/
create extension postgres_fdw;


-- remote_mount()
--
-- setup a foreign server to a remote, and import it's bundle schema

create or replace function remote_mount (
    foreign_server_name text,
    schema_name text,
    host text,
	port text,
    dbname text,
    username text,
    password text
)
returns boolean as
$$
begin
    execute format(
        'create server %I
            foreign data wrapper postgres_fdw
            options (host %L, port %L, dbname %L)',

        foreign_server_name, host, port, dbname
    );


    execute format(
        'create user mapping for public server %I options (user %L, password %L)',
        foreign_server_name, username, password
    );

    execute format(
        'create schema %I',
        schema_name
    );

    execute format(
        'import foreign schema bundle from server %I into %I options (import_default %L)',
        foreign_server_name, schema_name, 'true'
    );

    return true;
end;
$$ language plpgsql;




-- remote_diff ()
-- 
-- compare the bundles in two bundle schemas, typically a local one and a
-- remote one.  returns bundles present in the local but not the remote,
-- or visa versa.

create or replace function remote_diff( b1_schema_name text, b2_schema_name text )
returns table (
    b1_id uuid, b1_name text, b1_head_commit_id uuid,
    b2_id uuid, b2_name text, b2_head_commit_id uuid
)
as $$
begin
    return query execute format('
        select
            b1.id as b1_id, b1.name as b1_name, b1.head_commit_id as b1_head_commit_id,
            b2.id as b2_id, b2.name as b2_name, b2.head_commit_id as b2_head_commit_id
        from %I.bundle b1
            full outer join %I.bundle b2
                using (id, name)
        where b1.name is null or b2.name is null
        ', b1_schema_name, b2_schema_name
    );
end;
$$
language plpgsql;




-- remote_clone ()
--
-- copy a repository from one bundle schema (typically a remote) to another (typically a local one)

create or replace function remote_clone( bundle_id uuid, source_schema_name text, dest_schema_name text )
returns boolean as $$
begin
    -- rowset
    execute format ('insert into %2$I.rowset 
        select r.* from %1$I.commit c
            join %1$I.rowset r on c.rowset_id = r.id
        where c.bundle_id=%3$L', source_schema_name, dest_schema_name, bundle_id);

    -- rowset_row
    execute format ('
        insert into %2$I.rowset_row 
        select rr.* from %1$I.commit c 
            join %1$I.rowset r on c.rowset_id = r.id
            join %1$I.rowset_row rr on rr.rowset_id = r.id
        where c.bundle_id=%3$L', source_schema_name, dest_schema_name, bundle_id);

    -- blob
    execute format ('
        insert into %2$I.blob
        select b.* from %1$I.commit c 
            join %1$I.rowset r on c.rowset_id = r.id
            join %1$I.rowset_row rr on rr.rowset_id = r.id
            join %1$I.rowset_row_field f on f.rowset_row_id = rr.id
            join %1$I.blob b on f.value_hash = b.hash
        where c.bundle_id=%3$L', source_schema_name, dest_schema_name, bundle_id);

    -- rowset_row_field
    execute format ('
        insert into %2$I.rowset_row_field 
        select f.* from %1$I.commit c 
            join %1$I.rowset r on c.rowset_id = r.id
            join %1$I.rowset_row rr on rr.rowset_id = r.id
            join %1$I.rowset_row_field f on f.rowset_row_id = rr.id
        where c.bundle_id=%3$L', source_schema_name, dest_schema_name, bundle_id);

    -- bundle
    execute format ('insert into %2$I.bundle
		(id, name)
        select b.id, b.name from %1$I.bundle b
        where b.id=%3$L', source_schema_name, dest_schema_name, bundle_id);

    -- commit
    execute format ('
        insert into %2$I.commit
        select c.* from %1$I.commit c
        where c.bundle_id=%3$L', source_schema_name, dest_schema_name, bundle_id);

	execute format ('update %2$I.bundle
		set head_commit_id = (
        select b.head_commit_id
		from %1$I.bundle b
        where b.id=%3$L) where id=%3$L', source_schema_name, dest_schema_name, bundle_id);


    return true;
end;
$$
language plpgsql;


-- here's a table where you can stash some saved connections.
create table remote_database (
    id uuid default public.uuid_generate_v4() not null,
    foreign_server_name text,
    schema_name text,
    host text,
    port integer,
    dbname text,
    username text,
    password text
);



commit;
