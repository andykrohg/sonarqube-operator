ARG OPERATOR_SDK_VERSION=0.19.2

FROM quay.io/operator-framework/ansible-operator:v$OPERATOR_SDK_VERSION

COPY requirements.yml ${HOME}/requirements.yml
RUN ansible-galaxy collection install -r ${HOME}/requirements.yml \
 && chmod -R ug+rwx ${HOME}/.ansible

COPY watches.yaml ${HOME}/watches.yaml
COPY roles/ ${HOME}/roles/
COPY playbook.yml ${HOME}/playbook.yml
