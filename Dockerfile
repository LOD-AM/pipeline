# Build image of the LOD-AM data pipeline (planning#4; pipeline planning#3).
# Runs the make stages (planning#5) identically on the owner's machine, in CI and on a server.
# The image holds tools only, no data: this checkout (mapping, scripts) is mounted
# at /work at run time; out/ (snapshots, releases) and .cache/zotero are written there. See docker/README.md.
#
#   docker build -t lod-am-pipeline .
#   docker run --rm --network host --user "$(id -u):$(id -g)" --env-file .env -v "$PWD:/work" \
#     lod-am-pipeline fetch snapshot release                     # on the data LXC (README.md)
#
# Every input is pinned: base images by digest (Dependabot), Python by lock file with hashes,
# Ontop + JDBC by mapping/pom.xml, knowledge-graph by commit. A knowledge-graph bump is a
# deliberate change (new shapes can reject data): change KG_COMMIT in its own PR.

# Ontop CLI + PostgreSQL JDBC driver, at the versions in mapping/pom.xml
FROM maven:3.9.16-eclipse-temurin-17@sha256:1a352420f7aba21f5ad08df31bab55f74c013fb491f1ae8ab1dd7ff9ed698584 AS ontop
COPY mapping/pom.xml /build/pom.xml
RUN mvn -q -f /build/pom.xml dependency:copy-dependencies -DoutputDirectory=/opt/ontop/lib \
 && ls /opt/ontop/lib/ontop-cli-*.jar /opt/ontop/lib/postgresql-*.jar

# Java runtime for Ontop
FROM eclipse-temurin:17.0.21_9-jre@sha256:fb2cec8da84e3f086b59e29bf432d372e396fe0c247adcfb89303a28c2e313c0 AS jre

# PostgreSQL 16 + PostGIS 3.6 (Debian trixie); materialize loads the dump into a throwaway cluster.
# (16-3.5 is still Debian bullseye, whose PostgreSQL apt repository is gone.)
FROM postgis/postgis:16-3.6@sha256:d07ce3f06f657b6516c7511412232e97174d7e9dcf4c9fe520109b682b44a201
ARG KG_COMMIT=be9a5f3d60b5403d1927be867d725c9115409147
ARG KG_REPO=https://github.com/LOD-AM/knowledge-graph

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv git make curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --from=jre /opt/java/openjdk /opt/java/openjdk
COPY --from=ontop /opt/ontop/lib /opt/ontop/lib

COPY docker/requirements.txt /opt/requirements.txt
RUN python3 -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-cache-dir --require-hashes --only-binary=:all: -r /opt/requirements.txt

# knowledge-graph tools, shapes and vocabularies at a pinned commit, with the ontologies its
# checks read (CRM, CRMsci, CRMarchaeo, AFO, FaBiO) fetched now, not at run time
RUN git init -q /opt/knowledge-graph \
 && git -C /opt/knowledge-graph fetch -q --depth 1 "$KG_REPO" "$KG_COMMIT" \
 && git -C /opt/knowledge-graph checkout -q FETCH_HEAD \
 && bash /opt/knowledge-graph/tools/fetch_ontologies.sh \
 && chmod -R a+rX /opt/knowledge-graph

COPY docker/entrypoint.sh /usr/local/bin/lod-am-pipeline
# The mounted checkout belongs to the caller, the built-in knowledge-graph to root: git must read both
RUN chmod 755 /usr/local/bin/lod-am-pipeline \
 && git config --system --add safe.directory '*' \
 && useradd --uid 1000 --create-home lodam

ENV PATH=/opt/venv/bin:/opt/java/openjdk/bin:/usr/lib/postgresql/16/bin:$PATH \
    JAVA_HOME=/opt/java/openjdk \
    KG=/opt/knowledge-graph \
    ONTOP_LIB=/opt/ontop/lib \
    PG_BIN=/usr/lib/postgresql/16/bin \
    WORKDIR=/tmp
ARG PIPELINE_IMAGE=lod-am-pipeline:local
ENV PIPELINE_IMAGE=$PIPELINE_IMAGE

USER lodam
WORKDIR /work
ENTRYPOINT ["lod-am-pipeline"]
CMD ["release"]
