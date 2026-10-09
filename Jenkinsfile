pipeline {
    agent { label 'terraform-trusted' }
    options { timestamps(); timeout(time: 45, unit: 'MINUTES'); disableConcurrentBuilds(); skipDefaultCheckout(true) }
    parameters {
        choice(name:'ENVIRONMENT',choices:['nonprod','production','audit'])
        booleanParam(name:'APPLY',defaultValue:false,description:'Apply the reviewed saved plan')
    }
    stages {
        stage('Checkout') {
            steps { deleteDir(); checkout scm }
        }
        stage('Validate target') {
            steps {
                script {
                    if (!(params.ENVIRONMENT in ['nonprod', 'production', 'audit'])) {
                        error('Unsupported Terraform root')
                    }
                    env.TF_PLAN_DIR = sh(script: 'umask 077; mktemp -d /tmp/boutique-terraform-plan.XXXXXXXX', returnStdout: true).trim()
                }
            }
        }
        stage('Validate and plan') {
            steps {
                // File bindings live in Jenkins' private temporary directory,
                // outside the source checkout, and are removed after this block.
                // AWS authentication comes from the trusted agent's short-lived
                // workload identity; these files contain no AWS access keys.
                script {
                    def inputs=[file(credentialsId:"terraform-${params.ENVIRONMENT}-backend",variable:'TF_BACKEND_FILE'),file(credentialsId:"terraform-${params.ENVIRONMENT}-variables",variable:'TF_VARIABLES_FILE')]
                    if (params.ENVIRONMENT!='audit') { inputs << file(credentialsId:'rds-global-ca-bundle',variable:'RDS_CA_BUNDLE_PATH') }
                    withCredentials(inputs) {
                    sh '''set -eu
                        set +x
                        umask 077
                        if [ "$ENVIRONMENT" != audit ]; then
                        openssl crl2pkcs7 -nocrl -certfile "$RDS_CA_BUNDLE_PATH" | openssl pkcs7 -print_certs -noout >/dev/null
                        install -m 0600 "$RDS_CA_BUNDLE_PATH" "$TF_PLAN_DIR/rds-ca.pem"
                        export TF_VAR_monitoring_postgresql_ca_file="$TF_PLAN_DIR/rds-ca.pem"
                        set -- -var="monitoring_postgresql_ca_file=$TF_PLAN_DIR/rds-ca.pem"
                        else
                        set --
                        fi
                        terraform fmt -check -recursive
                        cd "environments/$ENVIRONMENT"
                        terraform init -input=false -backend-config="$TF_BACKEND_FILE"
                        terraform validate
                        terraform plan -input=false -var-file="$TF_VARIABLES_FILE" "$@" \
                          -out="$TF_PLAN_DIR/deployment.tfplan"
                        chmod 600 "$TF_PLAN_DIR/deployment.tfplan"
                        terraform show -json "$TF_PLAN_DIR/deployment.tfplan" \
                          | python3 "$WORKSPACE/scripts/summarize-plan.py" \
                          > "$WORKSPACE/plan-summary.json"
                        cat "$WORKSPACE/plan-summary.json"
                    '''
                }
                }
                archiveArtifacts artifacts: 'plan-summary.json', fingerprint: true
            }
        }
        stage('Approve apply') {
            when { expression { params.APPLY } }
            steps {
                script {
                    input message: "Review this build's redacted action summary, Terraform plan and cost impact. Apply the exact saved plan?\n${readFile('plan-summary.json')}", submitter: 'platform-admin'
                }
            }
        }
        stage('Apply saved plan') {
            when { expression { params.APPLY } }
            steps { sh 'cd "environments/$ENVIRONMENT" && terraform apply -input=false "$TF_PLAN_DIR/deployment.tfplan"' }
        }
    }
    post {
        always {
            sh '''set -eu
                case "${TF_PLAN_DIR:-}" in
                  /tmp/boutique-terraform-plan.*) rm -rf -- "$TF_PLAN_DIR" ;;
                  "") ;;
                  *) echo 'Unexpected plan directory; refusing cleanup.' >&2; exit 1 ;;
                esac
            '''
            deleteDir()
        }
    }
}
