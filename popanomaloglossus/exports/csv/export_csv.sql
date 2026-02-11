------------------------ POPAmphibien Anomaloglossus blanci - observation ------------------------------------
-- View: gn_monitoring.v_export_popanomaloglossus_observation
-- Export avec une entrée observations, permettant de récupérer les occurrences d'observations avec l'ensemble
-- des attributs spécifiques du protocole. Ne renvoie pas les visites sans observations.

DROP VIEW IF EXISTS gn_monitoring.v_export_popanomaloglossus_observation;

CREATE OR REPLACE VIEW gn_monitoring.v_export_popanomaloglossus_observation
AS WITH obs AS (
         SELECT cvo.id_base_visit,
            array_agg(r.id_role) AS ids_observers,
            string_agg(concat(r.nom_role, ' ', r.prenom_role), ' ; '::text) AS observers,
            string_agg(DISTINCT org.nom_organisme::text, ', '::text) AS organismes_rattaches
           FROM gn_monitoring.cor_visit_observer cvo
             JOIN utilisateurs.t_roles r USING (id_role)
             LEFT JOIN utilisateurs.bib_organismes org USING (id_organisme)
          GROUP BY cvo.id_base_visit
        ), com_dep AS (
         SELECT csa.id_base_site,
            la_com.area_name AS commune,
            la_dep.area_name AS departement,
            la_dep.area_code AS code_dep,
            row_number() OVER (PARTITION BY csa.id_base_site ORDER BY la_com.area_code) AS row_num
           FROM gn_monitoring.cor_site_area csa
             JOIN ref_geo.l_areas la_com ON csa.id_area = la_com.id_area
             JOIN ref_geo.bib_areas_types bat_com ON bat_com.id_type = la_com.id_type
             LEFT JOIN ref_geo.l_areas la_dep ON "left"(la_com.area_code::text, 2) = la_dep.area_code::text
             JOIN ref_geo.bib_areas_types bat_dep ON bat_dep.id_type = la_dep.id_type
          WHERE bat_com.type_code::text = 'COM'::text AND bat_dep.type_code::text = 'DEP'::text
        ), zonages AS (
         SELECT csa.id_base_site,
            string_agg(DISTINCT ((la.area_name::text || '('::text) || bat.type_code::text) || ')'::text, ', '::text) AS sites_proteges
           FROM ref_geo.l_areas la
             JOIN ref_geo.bib_areas_types bat ON la.id_type = bat.id_type
             JOIN gn_monitoring.cor_site_area csa ON csa.id_area = la.id_area
          WHERE bat.type_code::text = ANY (ARRAY['ZNIEFF1'::text, 'ZNIEFF2'::text, 'ZPS'::text, 'ZCS'::text, 'SIC'::text, 'RNCFS'::text, 'RNR'::text, 'RNN'::text, 'ZC'::text])
          GROUP BY csa.id_base_site
        ), info_sites AS (
         SELECT s_1.id_base_site,
            com_dep.departement,
            com_dep.code_dep,
            com_dep.commune,
            zonages.sites_proteges,
            s_1.altitude_min,
            s_1.altitude_max
           FROM gn_monitoring.t_base_sites s_1
             LEFT JOIN com_dep USING (id_base_site)
             LEFT JOIN zonages USING (id_base_site)
          WHERE com_dep.row_num = 1
        ), num_passages_calc AS (
         SELECT t_base_visits.id_base_visit,
	row_number() OVER (PARTITION BY t_base_visits.id_base_site, date_part('year'::text, t_base_visits.visit_date_min) ORDER BY t_base_visits.visit_date_min, (t_visit_complements.data ->> 'heure_debut'::text)) AS num_passage_calc
        FROM gn_monitoring.t_base_visits
        LEFT JOIN gn_monitoring.t_visit_complements USING (id_base_visit)
        )
 SELECT o.uuid_observation,
    replace(btrim(unaccent(tsg.sites_group_name::text)), ' '::text, '_'::text) AS transect,
    tsg.uuid_sites_group AS uuid_transect,
    tsg.sites_group_description AS description_transect,
    replace(btrim(unaccent(s.base_site_name::text)), ' '::text, '_'::text) AS sous_transect,
    st_astext(s.geom) AS wkt_wgs,
    st_x(st_centroid(s.geom)) AS x_wgs,
    st_y(st_centroid(s.geom)) AS y_wgs,
    i.altitude_min,
    i.altitude_max,
    i.departement,
    i.code_dep,
    i.commune,
    i.sites_proteges,
    s.base_site_description AS commentaire_sous_transect,
    v.id_dataset,
    d.dataset_name AS jeu_de_donnees,
    v.uuid_base_visit AS uuid_passage,
    v.visit_date_min AS date_passage,
    date_part('year'::text, v.visit_date_min) AS annee_passage,
    date_part('month'::text, v.visit_date_min) AS mois_passage,
    NULLIF(replace((vc.data::json -> 'heure_debut'::text)::text, '"'::text, ''::text), 'null'::text) AS heure_debut,
    NULLIF(replace((vc.data::json -> 'num_passage'::text)::text, '"'::text, ''::text), 'null'::text) AS num_passage,
    npc.num_passage_calc,
    NULLIF(replace((vc.data::json -> 'expertise'::text)::text, '"'::text, ''::text), 'null'::text) AS expertise_operateur,
    NULLIF(replace((vc.data::json -> 'nb_observers'::text)::text, '"'::text, ''::text), 'null'::text) AS nb_observateurs,
    NULLIF(replace((vc.data::json -> 'pluie'::text)::text, '"'::text, ''::text), 'null'::text) AS pluie,
    NULLIF(replace((vc.data::json -> 'eau'::text)::text, '"'::text, ''::text), 'null'::text) AS eau_crique,
    obs.observers,
    obs.organismes_rattaches,
    v.comments AS commentaire_passage,
    o.cd_nom,
    t.lb_nom AS nom_latin,
    t.nom_vern AS nom_francais,
    NULLIF(replace((oc.data::json -> 'count'::text)::text, '"'::text, ''::text), 'null'::text) AS nombre,
    ref_nomenclatures.get_nomenclature_label(NULLIF(json_extract_path(oc.data::json, VARIADIC ARRAY['id_nomenclature_stade'::text])::text, 'null'::text)::integer, 'fr'::character varying) AS stade_vie,
    ref_nomenclatures.get_nomenclature_label(NULLIF(json_extract_path(oc.data::json, VARIADIC ARRAY['id_nomenclature_sex'::text])::text, 'null'::text)::integer, 'fr'::character varying) AS sexe,
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
  ORDER BY v.id_dataset, tsg.sites_group_name, s.base_site_name, v.visit_date_min, (NULLIF(replace((vc.data::json -> 'heure_debut')::text, '"', ''), 'null'));
