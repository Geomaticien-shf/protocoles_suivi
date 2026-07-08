---------------------------------------------------POPReptile standard------------------------------------------
-- View: gn_monitoring.v_export_popreptile_standard

DROP VIEW IF EXISTS gn_monitoring.v_export_popreptile_standard;

CREATE OR REPLACE VIEW gn_monitoring.v_export_popreptile_standard AS
WITH obs AS
(SELECT
    id_base_visit,
    array_agg(r.id_role) AS ids_observers,
    string_agg(concat(r.nom_role, ' ', r.prenom_role), ' ; ') AS observers,
    string_agg(DISTINCT org.nom_organisme::text, ', ') AS organismes_rattaches
FROM gn_monitoring.cor_visit_observer cvo
JOIN utilisateurs.t_roles r USING (id_role)
-- Pour que les observateurs apparaissent même s'ils ne sont pas rattachés à un organisme
LEFT JOIN utilisateurs.bib_organismes org USING (id_organisme)
GROUP BY id_base_visit),
com_dep AS (
SELECT
    csa.id_base_site,
    la_com.area_name AS commune,
    la_dep.area_name AS departement,
    la_dep.area_code AS code_dep,
    -- Permettra de filtrer pour n'avoir qu'un ensemble (commune - département) par observation
    ROW_NUMBER() OVER (PARTITION BY csa.id_base_site ORDER BY la_com.area_code) AS row_num
FROM gn_monitoring.cor_site_area csa
JOIN ref_geo.l_areas la_com ON csa.id_area = la_com.id_area
JOIN ref_geo.bib_areas_types bat_com ON bat_com.id_type = la_com.id_type
LEFT JOIN ref_geo.l_areas la_dep ON LEFT(la_com.area_code, 2) = la_dep.area_code
JOIN ref_geo.bib_areas_types bat_dep ON bat_dep.id_type = la_dep.id_type
WHERE bat_com.type_code = 'COM' AND bat_dep.type_code = 'DEP'),
zonages AS
(SELECT
    csa.id_base_site,
    string_agg(DISTINCT ((la.area_name::text || '(') ||bat.type_code::text) || ')', ', ') AS sites_proteges
FROM ref_geo.l_areas la
JOIN ref_geo.bib_areas_types bat ON la.id_type = bat.id_type
JOIN gn_monitoring.cor_site_area csa ON csa.id_area = la.id_area
WHERE bat.type_code = ANY (ARRAY['ZNIEFF1', 'ZNIEFF2', 'ZPS', 'ZCS', 'SIC', 'RNCFS', 'RNR', 'RNN', 'ZC']::text[]) -- A reprendre ultérieurement
GROUP BY id_base_site
),
info_sites AS
(SELECT
    s.id_base_site,
    departement,
    code_dep,
    commune,
    sites_proteges
FROM gn_monitoring.t_base_sites s
LEFT JOIN com_dep USING (id_base_site)
LEFT JOIN zonages USING (id_base_site)
-- On s'assure de ne prendre qu'un ensemble (commune - département) par observation
WHERE row_num = 1),
num_passages_calc AS
(SELECT
    id_base_visit,
    row_number() OVER (PARTITION BY id_base_site, date_part('year', visit_date_min) ORDER BY visit_date_min ASC, (c.data->>'Heure_debut')) as num_passage_calc
FROM gn_monitoring.t_base_visits
LEFT JOIN gn_monitoring.t_visit_complements c USING (id_base_visit)
)
SELECT
    -- identifiant unique : doit être en première position (cf issue #582 monitoring)
    o.uuid_observation,
    -- Version de la vue pour pouvoir vérifier simplement si à jour
    1 AS version,
    -- Aire et variables associées (groupe de sites)
    REPLACE(trim(unaccent(tsg.sites_group_name)), ' ', '_') AS aire_etude, -- Uniformisation des noms
    tsg.uuid_sites_group AS uuid_aire_etude,
    tsg.sites_group_description AS description_aire,
    NULLIF(REPLACE((tsg.data::json->'habitat_principal')::text,'"',''),'null') AS habitat_principal_aire,
    tsg.comments AS commentaire_aire,
    -- Transect et variables associées (site)
    REPLACE(trim(unaccent(s.base_site_name)), ' ', '_') AS nom_transect, -- Uniformisation transect
    st_astext(s.geom) AS wkt_wgs,
    st_x(st_centroid(s.geom)) AS x_centroid_wgs,
    st_y(st_centroid(s.geom)) AS y_centroid_wgs,
    -- le cast en "geography" permet de s'assurer que le résultat sera en mètre
    round(ST_length(s.geom::geography)) AS longueur_transect,
    s.altitude_min,
    s.altitude_max,
    i.departement AS departement,
    i.code_dep AS code_dep,
    i.commune AS commune,
    i.sites_proteges AS sites_proteges,
    NULLIF(REPLACE((sc.DATA::json->'milieu_transect')::TEXT,'"', ''), 'null') AS milieu_transect,
    s.base_site_description AS commentaire_transect,
    -- Informations sur le passage (visite)
    v.id_dataset,
    d.dataset_name AS jeu_de_donnees,
    v.uuid_base_visit AS uuid_passage,
    v.visit_date_min AS date_passage,
    date_part('year', v.visit_date_min) AS annee_passage,
    date_part('month', v.visit_date_min) AS mois_passage,
    NULLIF(REPLACE((vc.data::json->'Heure_debut')::text,'"',''),'null') AS heure_debut,
    NULLIF(REPLACE((vc.data::json->'Heure_fin')::text,'"',''),'null') AS heure_fin,
    NULLIF(REPLACE((vc.data::json->'num_passage')::text,'"',''),'null') AS num_passage,
    npc.num_passage_calc,
    NULLIF(REPLACE((vc.data::json->'expertise')::text,'"',''),'null') AS expertise_operateur,
    NULLIF(REPLACE((vc.data::json->'methode_prospection')::text,'"',''),'null') AS methode_prospection,
    NULLIF(REPLACE((vc.data::json->'accessibility')::text, '"', ''), 'null') AS accessibilite,
    NULLIF(REPLACE((vc.data::json->'etat_site')::text, '"', ''), 'null') AS etat_site,
    NULLIF(REPLACE((vc.data::json->'date_changement_etat_site')::text, '"', ''), 'null') AS date_changement_etat_site,
    obs.observers,
    obs.organismes_rattaches,
    v.comments AS commentaire_passage,
    -- Informations sur l'observation
    o.cd_nom,
    NULLIF(REPLACE((oc.data::json->'presence')::text,'"',''),'null') AS presence_reptile,
    t.lb_nom AS nom_latin,
    t.nom_vern AS nom_francais,
    ref_nomenclatures.get_nomenclature_label(NULLIF(json_extract_path(oc.data::json,'id_nomenclature_typ_denbr')::text, 'null')::integer, 'fr') AS type_denombrement,
	NULLIF(REPLACE((oc.data::json->'count_min')::text,'"',''),'null') AS nombre_min,
	NULLIF(REPLACE((oc.data::json->'count_max')::text,'"',''),'null') AS nombre_max,
    ref_nomenclatures.get_nomenclature_label(NULLIF(json_extract_path(oc.data::json,'id_nomenclature_stade')::text,'null')::integer, 'fr') AS stade_vie,
    ref_nomenclatures.get_nomenclature_label(NULLIF(json_extract_path(oc.data::json,'id_nomenclature_sex')::text,'null')::integer, 'fr') AS sexe,
    o.comments AS commentaire_obs
FROM gn_monitoring.t_observations o
JOIN gn_monitoring.t_observation_complements oc USING (id_observation)
JOIN gn_monitoring.t_base_visits v USING (id_base_visit)
JOIN num_passages_calc npc USING (id_base_visit)
JOIN gn_monitoring.t_visit_complements vc USING (id_base_visit)
JOIN gn_monitoring.t_base_sites s USING (id_base_site)
JOIN gn_monitoring.t_site_complements sc USING (id_base_site)
JOIN gn_monitoring.t_sites_groups tsg USING (id_sites_group)
JOIN gn_commons.t_modules m ON m.id_module = v.id_module
JOIN taxonomie.taxref t USING (cd_nom)
LEFT JOIN gn_meta.t_datasets d USING (id_dataset)
LEFT JOIN info_sites i USING (id_base_site)
LEFT JOIN obs USING (id_base_visit)
WHERE m.module_code = :module_code
ORDER BY v.id_dataset, tsg.sites_group_name, s.base_site_name, v.visit_date_min;

--------------------------------------------------POPReptile analyses------------------------------------------
-- View: gn_monitoring.v_export_popreptile_analyse
DROP VIEW IF EXISTS gn_monitoring.v_export_popreptile_analyses;

CREATE OR REPLACE VIEW gn_monitoring.v_export_popreptile_analyses AS
WITH observations AS (
    SELECT
        o.id_base_visit,
        -- Attention, comptabilise les 'Squamata' mais il le faut, car potentiellement, on peut avoir vu une observation de Squamata sans le déterminer
        count(DISTINCT t.cd_ref) AS diversite,
        string_agg(DISTINCT t.lb_nom::text, ' ; '::text) AS taxons_latin,
        string_agg(DISTINCT t.nom_vern::text, ' ; '::text) AS taxons_fr,
        sum(NULLIF(REPLACE((oc.data::json->'count_min')::text,'"',''),'null')::integer) AS count_min,
        sum(NULLIF(REPLACE((oc.data::json->'count_max')::text,'"',''),'null')::integer) AS count_max
    FROM gn_monitoring.t_observations o
    LEFT JOIN taxonomie.taxref t ON o.cd_nom = t.cd_nom
    LEFT JOIN gn_monitoring.t_observation_complements oc ON oc.id_observation = o.id_observation
    WHERE oc.data->>'presence' = 'Oui'
    GROUP BY o.id_base_visit
),
obs AS
(SELECT
    id_base_visit,
    array_agg(r.id_role) AS ids_observers,
    string_agg(concat(r.nom_role, ' ', r.prenom_role), ' ; ') AS observers,
    string_agg(DISTINCT org.nom_organisme::text, ', ') AS organismes_rattaches
FROM gn_monitoring.cor_visit_observer cvo
JOIN utilisateurs.t_roles r USING (id_role)
-- Pour que les observateurs apparaissent même s'ils ne sont pas rattachés à un organisme
LEFT JOIN utilisateurs.bib_organismes org USING (id_organisme)
GROUP BY id_base_visit),
com_dep AS (
SELECT
    csa.id_base_site,
    la_com.area_name AS commune,
    la_dep.area_name AS departement,
    la_dep.area_code AS code_dep,
    -- Permettra de filtrer pour n'avoir qu'un ensemble (commune - département) par observation
    ROW_NUMBER() OVER (PARTITION BY csa.id_base_site ORDER BY la_com.area_code) AS row_num
FROM gn_monitoring.cor_site_area csa
JOIN ref_geo.l_areas la_com ON csa.id_area = la_com.id_area
JOIN ref_geo.bib_areas_types bat_com ON bat_com.id_type = la_com.id_type
LEFT JOIN ref_geo.l_areas la_dep ON LEFT(la_com.area_code, 2) = la_dep.area_code
JOIN ref_geo.bib_areas_types bat_dep ON bat_dep.id_type = la_dep.id_type
WHERE bat_com.type_code = 'COM' AND bat_dep.type_code = 'DEP'),
zonages AS
(SELECT
    csa.id_base_site,
    string_agg(DISTINCT ((la.area_name::text || '(') ||bat.type_code::text) || ')', ', ') AS sites_proteges
FROM ref_geo.l_areas la
JOIN ref_geo.bib_areas_types bat ON la.id_type = bat.id_type
JOIN gn_monitoring.cor_site_area csa ON csa.id_area = la.id_area
WHERE bat.type_code = ANY (ARRAY['ZNIEFF1', 'ZNIEFF2', 'ZPS', 'ZCS', 'SIC', 'RNCFS', 'RNR', 'RNN', 'ZC']::text[]) -- A reprendre ultérieurement
GROUP BY id_base_site
),
info_sites AS
(SELECT
    s.id_base_site,
    departement,
    code_dep,
    commune,
    sites_proteges
FROM gn_monitoring.t_base_sites s
LEFT JOIN com_dep USING (id_base_site)
LEFT JOIN zonages USING (id_base_site)
-- On s'assure de ne prendre qu'un ensemble (commune - département) par observation
WHERE row_num = 1),
num_passages_calc AS
(SELECT
    id_base_visit,
    row_number() OVER (PARTITION BY id_base_site, date_part('year', visit_date_min) ORDER BY visit_date_min ASC, (c.data->>'Heure_debut')) as num_passage_calc
FROM gn_monitoring.t_base_visits
LEFT JOIN gn_monitoring.t_visit_complements c USING (id_base_visit)
)
SELECT
    -- Doit être en premier, cf issue #582 (monitoring)
    v.uuid_base_visit AS uuid_passage,
    -- Version de la vue pour pouvoir vérifier simplement si à jour
    1 AS version,
    -- Aire et site
    REPLACE(trim(unaccent(tsg.sites_group_name)), ' ', '_') AS aire_etude, -- Uniformisation des noms
    tsg.uuid_sites_group AS uuid_aire_etude,
    tsg.sites_group_description AS description_aire,
    NULLIF(REPLACE((tsg.data::json->'habitat_principal')::text,'"',''),'null') AS habitat_principal_aire,
    tsg.comments AS commentaire_aire,
    REPLACE(trim(unaccent(s.base_site_name)), ' ', '_') AS nom_transect, -- Uniformisation transect
    st_astext(s.geom) AS wkt_wgs,
    st_x(st_centroid(s.geom)) AS x_centroid_wgs,
    st_y(st_centroid(s.geom)) AS y_centroid_wgs,
    s.altitude_min,
    s.altitude_max,
    i.departement AS departement,
    i.code_dep AS code_dep,
    i.commune AS commune,
    i.sites_proteges AS sites_proteges,
    NULLIF(REPLACE((sc.DATA::json->'milieu_transect')::TEXT,'"', ''), 'null') AS milieu_transect,
    s.base_site_description AS commentaire_transect,
    -- Informations sur le passage (visite)
    v.id_dataset,
    d.dataset_name AS jeu_de_donnees,
    v.visit_date_min AS date_passage,
    date_part('year', v.visit_date_min) AS annee_passage,
    date_part('month', v.visit_date_min) AS mois_passage,
    NULLIF(REPLACE((vc.data::json->'Heure_debut')::text,'"',''),'null') AS heure_debut,
    NULLIF(REPLACE((vc.data::json->'Heure_fin')::text,'"',''),'null') AS heure_fin,
    NULLIF(REPLACE((vc.data::json->'num_passage')::text,'"',''),'null') AS num_passage,
    npc.num_passage_calc,
    NULLIF(REPLACE((vc.data::json->'expertise')::text,'"',''),'null') AS expertise_operateur,
    NULLIF(REPLACE((vc.data::json->'methode_prospection')::text,'"',''),'null') AS methode_prospection,
    NULLIF(REPLACE((vc.data::json->'accessibility')::text, '"', ''), 'null') AS accessibilite,
    NULLIF(REPLACE((vc.data::json->'etat_site')::text, '"', ''), 'null') AS etat_site,
    NULLIF(REPLACE((vc.data::json->'date_changement_etat_site')::text, '"', ''), 'null') AS date_changement_etat_site,
    obs.observers,
    obs.organismes_rattaches,
    v.comments AS commentaire_passage,
    -- synthese observations
    observations.diversite::integer AS diversite,
    observations.taxons_latin,
    observations.taxons_fr,
    observations.count_min AS abondance_total_min,
    observations.count_max AS abondance_total_max
FROM gn_monitoring.t_base_visits v
JOIN num_passages_calc npc USING (id_base_visit)
JOIN gn_monitoring.t_visit_complements vc USING (id_base_visit)
JOIN gn_monitoring.t_base_sites s USING (id_base_site)
JOIN gn_monitoring.t_site_complements sc USING (id_base_site)
JOIN gn_monitoring.t_sites_groups tsg USING (id_sites_group)
JOIN gn_commons.t_modules m ON m.id_module = v.id_module
LEFT JOIN observations USING (id_base_visit)
LEFT JOIN gn_meta.t_datasets d ON d.id_dataset = v.id_dataset
LEFT JOIN info_sites i USING (id_base_site)
LEFT JOIN obs USING (id_base_visit)
WHERE m.module_code = :module_code
ORDER BY v.id_dataset, tsg.sites_group_name, s.base_site_name, visit_date_min;


--------------------------------------------------POPReptile erreurs------------------------------------------
DROP VIEW IF EXISTS gn_monitoring.v_export_popreptile_erreurs;

CREATE OR REPLACE VIEW gn_monitoring.v_export_popreptile_erreurs AS
WITH nb_sites_par_aire AS
(SELECT DISTINCT
	id_sites_group,
	count(DISTINCT id_base_site) AS nb_sites
FROM gn_monitoring.t_sites_groups tsg
LEFT JOIN gn_monitoring.t_site_complements USING (id_sites_group)
LEFT JOIN gn_monitoring.cor_sites_group_module USING (id_sites_group)
LEFT JOIN gn_commons.t_modules tm USING (id_module)
WHERE (module_code = :module_code)
GROUP BY id_sites_group),
nb_visits_par_site AS
(SELECT DISTINCT
	id_base_site, count(DISTINCT id_base_visit) AS nb_visits
FROM gn_monitoring.t_base_sites s
LEFT JOIN gn_monitoring.t_base_visits USING (id_base_site)
LEFT JOIN gn_commons.t_modules tm USING (id_module)
WHERE (module_code = :module_code)
GROUP BY id_base_site),
pb_num_passages AS
(SELECT DISTINCT
	tsg.sites_group_name AS aire_etude,
	array_agg(CONCAT(nom_transect, '_', annee_passage, '_', num_passage) ORDER BY nom_transect, annee_passage DESC, num_passage) AS list_tr_num_pb,
	COALESCE(tsg.id_digitiser, (tsg.DATA->>'id_inventor')::int) AS id_user
FROM gn_monitoring.v_export_popreptile_analyses
LEFT JOIN gn_monitoring.t_sites_groups tsg ON (uuid_aire_etude = tsg.uuid_sites_group)
WHERE num_passage::int <> num_passage_calc::int
GROUP BY tsg.sites_group_name, id_user),
info_visits AS
(SELECT DISTINCT
	g.sites_group_name AS aire_etude,
	s.base_site_name AS transect,
	id_base_visit,
	COALESCE(g.id_digitiser, (g.DATA->>'id_inventor')::int) AS id_user,
	count(DISTINCT id_observation) AS nb_obs
FROM gn_monitoring.t_base_visits v
LEFT JOIN gn_meta.t_datasets td USING (id_dataset)
LEFT JOIN gn_monitoring.t_base_sites s USING (id_base_site)
LEFT JOIN gn_monitoring.t_site_complements tsc USING (id_base_site)
LEFT JOIN gn_monitoring.t_sites_groups g USING (id_sites_group)
LEFT JOIN gn_monitoring.t_visit_complements tvc USING (id_base_visit)
LEFT JOIN gn_monitoring.t_observations t USING (id_base_visit)
LEFT JOIN gn_commons.t_modules tm USING (id_module)
WHERE (module_code = :module_code
	AND (tvc.DATA->>'etat_site' <> 'Transect détruit (travaux, etc.)' OR tvc.DATA->>'etat_site' IS NULL)
	AND tvc.DATA->>'accessibility' <> 'Non')
GROUP BY aire_etude, transect, id_base_visit, id_user
ORDER BY nb_obs),
pb_visite_vide AS
(SELECT aire_etude, id_user, array_agg(DISTINCT transect) AS trs
FROM info_visits
WHERE nb_obs = 0
GROUP BY aire_etude, id_user),
pb_visite_presence_absence AS
(	select uuid_passage,
	count(distinct v.presence_reptile) as abs_pres,
	tsg.sites_group_name AS aire_etude,
	array_agg(distinct CONCAT(nom_transect,'_', date_passage)) as details,
	COALESCE(tsg.id_digitiser, (tsg.DATA->>'id_inventor')::int) AS id_user
from gn_monitoring.v_export_popreptile_standard v
LEFT JOIN gn_monitoring.t_sites_groups tsg ON (uuid_aire_etude = tsg.uuid_sites_group)
group by uuid_passage, sites_group_name, id_digitiser, tsg.data->>'id_inventor'
),
taxon_pb AS
(SELECT DISTINCT
	tsg.sites_group_name AS aire_etude,
	cd_nom, cd_ref,
	array_agg(CONCAT(nom_transect, '_', annee_passage, '_', num_passage) ORDER BY nom_transect, date_passage DESC) AS list_pb,
	COALESCE(tsg.id_digitiser, (tsg.DATA->>'id_inventor')::int) AS id_user
FROM gn_monitoring.v_export_popreptile_standard v
LEFT JOIN taxonomie.taxref t USING (cd_nom)
LEFT JOIN gn_monitoring.t_sites_groups tsg ON (uuid_aire_etude = tsg.uuid_sites_group)
WHERE cd_nom <> cd_ref or (ordre not in ('Squamata'))
GROUP BY tsg.sites_group_name, id_user, cd_nom, cd_ref),
errors AS
((
-- Aires vides, sans aucun site
SELECT
	'Aire vide' AS type_erreur,
	NULL AS details_erreur,
	'Doublon d''une autre aire, erreur de saisie aire ou oubli de saisie transects' AS risques,
	tsg.sites_group_name AS aire_etude,
	COALESCE(NULLIF(CONCAT(d.prenom_role, ' ', d.nom_role), ' '), CONCAT(inventor.prenom_role, ' ', inventor.nom_role)) AS nom_digitiser,
	COALESCE(d.email, inventor.email) AS email_digitiser
FROM nb_sites_par_aire
LEFT JOIN gn_monitoring.t_sites_groups tsg USING (id_sites_group)
LEFT JOIN utilisateurs.t_roles d ON (d.id_role = tsg.id_digitiser)
LEFT JOIN utilisateurs.t_roles inventor ON (inventor.id_role = (tsg.DATA->>'id_inventor')::int)
WHERE nb_sites = 0)
UNION
(
-- Transects vides, sans aucune visite
SELECT DISTINCT
	'Transect vide' AS type_erreur,
	CONCAT('Nom transect : ', s.base_site_name) AS details_erreur,
	'Doublon d''un autre transect, erreur de saisie transect ou oubli de saisie visites' AS risques,
	tsg.sites_group_name AS aire_etude,
	NULLIF(CONCAT(d.prenom_role, ' ', d.nom_role), ' ') AS nom_digitiser,
	d.email AS email_digitiser
FROM nb_visits_par_site
LEFT JOIN gn_monitoring.t_base_sites s USING (id_base_site)
LEFT JOIN gn_monitoring.t_site_complements c USING (id_base_site)
LEFT JOIN gn_monitoring.t_sites_groups tsg USING (id_sites_group)
LEFT JOIN utilisateurs.t_roles d ON (d.id_role = s.id_digitiser)
WHERE nb_visits = 0)
UNION
(
SELECT
	'Numéro de passage incorrect' AS type_erreur,
	CONCAT('Transects_annee_numero concernés : ', array_to_string(list_tr_num_pb, ' | ')) AS details_erreur,
	'Simple pb de numérotation, oubli de saisie visites, erreur date' AS risques,
	aire_etude,
	NULLIF(CONCAT(d.prenom_role, ' ', d.nom_role), ' ') AS nom_digitiser,
	d.email AS email_digitiser
FROM pb_num_passages
LEFT JOIN utilisateurs.t_roles d ON (d.id_role = id_user)
ORDER BY aire_etude)
UNION
(
SELECT
	'Visite vide (sans observation)' AS type_erreur,
	CONCAT('Transects concernés : ', array_to_string(trs, ' | ')) AS details_erreur,
	'Oubli de saisie d''observation ou d''absence, erreur de saisie de la visite' AS risques,
	aire_etude,
	NULLIF(CONCAT(d.prenom_role, ' ', d.nom_role), ' ') AS nom_digitiser,
	d.email AS email_digitiser
FROM pb_visite_vide
LEFT JOIN utilisateurs.t_roles d ON (d.id_role = id_user)
)
UNION
(
SELECT
	'Taxon non ciblé par le protocole' AS type_erreur,
	CONCAT('Taxon concerné (cd_nom) : ', cd_nom, '; Passages concernés : ', array_to_string(list_pb, ' | ')) AS details_erreur,
	'Mauvaise traduction de présence/absence de reptiles dans les analyses' AS risques,
	aire_etude,
	NULLIF(CONCAT(d.prenom_role, ' ', d.nom_role), ' ') AS nom_digitiser,
	d.email AS email_digitiser
FROM taxon_pb
LEFT JOIN utilisateurs.t_roles d ON (d.id_role = id_user)
WHERE cd_nom = cd_ref
)
UNION
(
SELECT
	'Taxon non à jour (cd_nom <> cd_ref)' AS type_erreur,
	CONCAT('Taxon concerné (cd_nom) : ', cd_nom, '; Passages concernés : ', array_to_string(list_pb, ' | ')) AS details_erreur,
	'Mauvaise traduction de présence/absence de reptiles dans les analyses' AS risques,
	aire_etude,
	NULLIF(CONCAT(d.prenom_role, ' ', d.nom_role), ' ') AS nom_digitiser,
	d.email AS email_digitiser
FROM taxon_pb
LEFT JOIN utilisateurs.t_roles d ON (d.id_role = id_user)
WHERE cd_nom <> cd_ref
)
UNION
(
SELECT
	'Visite avec présence et absence reptile' AS type_erreur,
	CONCAT('Passage concerné : ', array_to_string(details, ' | ')) AS details_erreur,
	'Erreur de saisie : que conserver ?' AS risques,
	aire_etude,
	NULLIF(CONCAT(d.prenom_role, ' ', d.nom_role), ' ') AS nom_digitiser,
	d.email AS email_digitiser
FROM pb_visite_presence_absence
LEFT JOIN utilisateurs.t_roles d ON (d.id_role = id_user)
where abs_pres > 1
))
SELECT
	row_number() OVER(order by type_erreur, aire_etude) as numero_ligne,
	'0.1' as version,
	*
FROM errors
ORDER BY type_erreur, aire_etude;
