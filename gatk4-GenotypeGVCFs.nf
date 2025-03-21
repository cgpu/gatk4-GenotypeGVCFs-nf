#!/usr/bin/env nextflow

// Copyright (C) 2018 IARC/WHO

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

params.help = null

log.info ""
log.info "-------------------------------------------------------------------------"
log.info "  gatk4-GenotypeGVCFs v1: Exact Joint Genotyping GATK4 Best Practices         "
log.info "-------------------------------------------------------------------------"
log.info "Copyright (C) IARC/WHO"
log.info "This program comes with ABSOLUTELY NO WARRANTY; for details see LICENSE"
log.info "This is free software, and you are welcome to redistribute it"
log.info "under certain conditions; see LICENSE for details."
log.info "-------------------------------------------------------------------------"
log.info ""

if (params.help)
{
    log.info "---------------------------------------------------------------------"
    log.info "                             USAGE                                   "
    log.info "---------------------------------------------------------------------"
    log.info ""
    log.info "nextflow run iarcbioinfo/gatk4-GenotypeGVCFs-nf [OPTIONS]"
    log.info ""
    log.info "Mandatory arguments:"
    log.info "--inputdir_file_regex           VCF FILES                 All cohort gVCF files (between quotes)"
    log.info "--ref_fasta                     FASTA FILE                Reference FASTA file"
    exit 1
}

// Parse Input Parameters
gvcf_ch = Channel
			.fromPath("${params.inputdir_file_regex}/*.g.vcf")

gvcf_idx_ch = Channel
			.fromPath("${params.inputdir_file_regex}/*.g.vcf.idx")
			
ref                               = file(params.ref_fasta)
dbsnp_resource_vcf                = file(params.dbsnp)
mills_resource_vcf                = file(params.mills)
axiomPoly_resource_vcf            = file(params.axiom)
hapmap_resource_vcf               = file(params.hapmap)
omni_resource_vcf                 = file(params.omni)
one_thousand_genomes_resource_vcf = file(params.onekg)

// ExcessHet is a phred-scaled p-value. We want a cutoff of anything more extreme
// than a z-score of -4.5 which is a p-value of 3.4e-06, which phred-scaled is 54.69
excess_het_threshold = 54.69

// Store the chromosomes in a channel for easier workload scattering on large cohort
chromosomes_ch = Channel
    .from( "chr1", "chr2", "chr3", "chr4", "chr5", "chr6", "chr7", "chr8", "chr9", "chr10", "chr11", "chr12", "chr13", "chr14", "chr15", "chr16", "chr17", "chr18", "chr19", "chr20", "chr21", "chr22", "chrX", "chrY" )


//
// Process launching GenomicsDBImport to gather all VCFs, per chromosome
//
process GenomicsDBImport {

    container 'broadinstitute/gatk:latest'

	cpus 1 

    time { (10.hour + (2.hour * task.attempt)) } // First attempt 12h, second 14h, etc
    memory { (16.GB + (8.GB * task.attempt)) } // First attempt 72GB, second 80GB, etc

    errorStrategy 'retry'
    maxRetries 3

	tag { chr }

    input:
	each chr from chromosomes_ch
    file (gvcf) from gvcf_ch.collect()
	file (gvcf_idx) from gvcf_idx_ch.collect()

	output:
    set chr, file ("${params.cohort}.${chr}") into gendb_ch
	
    script:
	"""
	gatk GenomicsDBImport --java-options "-Xmx24g -Xms24g -Djava.io.tmpdir=/tmp" \
	${gvcf.collect { "-V $it " }.join()} \
    -L ${chr} \
    --batch-size 50 \
    --tmp-dir=/tmp \
	--genomicsdb-workspace-path ${params.cohort}.${chr}
	
	"""
}	

// Process launching GenotypeGVCFs on the previously created genDB, per chromosome
process GenotypeGVCFs {

    container 'broadinstitute/gatk:latest'

	cpus 4 
	memory '12 GB'
	time '20h'
	
	tag { chr }

	publishDir params.output_dir, mode: 'copy', pattern: '*.{vcf,idx}'

    input:
	set chr, file (workspace) from gendb_ch
   	file genome from ref

	output:
    set chr, file("${params.cohort}.${chr}.vcf"), file("${params.cohort}.${chr}.vcf.idx") into vcf_ch
    file "${genome}.fai" into faidx_sid_ch,faidx_snv_ch
	file "${genome.baseName}.dict" into dict_sid_ch,dict_snv_ch

    script:
	"""
    samtools faidx ${genome}

    java -jar \$PICARD_TOOLS_LIBDIR/picard.jar \
    CreateSequenceDictionary \
    R=${genome} \
    O=${genome.baseName}.dict

    WORKSPACE=\$( basename ${workspace} )

    gatk --java-options "-Xmx5g -Xms5g" \
     GenotypeGVCFs \
     -R ${genome} \
     -O ${params.cohort}.${chr}.vcf \
     -D ${dbsnp_resource_vcf} \
     -G StandardAnnotation \
     --only-output-calls-starting-in-intervals \
     --use-new-qual-calculator \
     -V gendb://\$WORKSPACE \
     -L ${chr}

	"""
}	

// Process Hard Filtering on ExcessHet, per chromosome
process HardFilter {

    container 'broadinstitute/gatk:latest'

	cpus 1
	memory '12 GB'
	time '12h'
	
	tag { chr }

    input:
	set chr, file (vcf), file (vcfidx) from vcf_ch

	output:
    file("${params.cohort}.${chr}.filtered.vcf") into (vcf_hf_ch)
    file("${params.cohort}.${chr}.filtered.vcf.idx") into (vcf_idx_hf_ch)

    script:
	"""
	gatk --java-options "-Xmx3g -Xms3g" \
      VariantFiltration \
      --filter-expression "ExcessHet > ${excess_het_threshold}" \
      --filter-name ExcessHet \
      -V ${vcf} \
      -O ${params.cohort}.${chr}.markfiltered.vcf

	gatk --java-options "-Xmx3g -Xms3g" \
      SelectVariants \
      --exclude-filtered \
      -V ${params.cohort}.${chr}.markfiltered.vcf \
      -O ${params.cohort}.${chr}.filtered.vcf

	"""
}	

process GatherVcfs {

    container 'broadinstitute/gatk:latest'

	cpus 1
	memory '12 GB'
	time '12h'
	
	tag "${params.cohort}"

    input:
    file (vcf) from vcf_hf_ch.collect()
	file (vcf_idx) from vcf_idx_hf_ch.collect()

	output:
    set file("${params.cohort}.vcf"), file("${params.cohort}.vcf.idx") into (vcf_snv_ch, vcf_sid_ch, vcf_recal_ch)

    // WARNING : complicated channel extraction! 
    // GATK GatherVcfs only accepts as input VCF in the chromosomical order. Nextflow/Groovy list are not sorted. The following command does :
    // 1 : look for all VCF with "chr[0-9]*" in the filename (\d+ means 1 or + digits)
    // 2 : Tokenize the filenames with "." as the separator, keep the 2nd item (indexed [1]) "chr[0-9]*"
    // 3 : Take from the 3rd character till the end of the string "chr[0-9]*", ie the chromosome number
    // 4 : Cast it from a string to an integer (to force a numerical sort)
    // 5 : Sort 
    // 6 : Add chrX and chrY to the list

    script:
	"""
	gatk --java-options "-Xmx3g -Xms3g" \
      GatherVcfs \
      ${vcf.findAll{ it=~/chr\d+/ }.collect().sort{ it.name.tokenize('.')[1].substring(3).toInteger() }.plus(vcf.find{ it=~/chrX/ }).plus(vcf.find{ it=~/chrY/ }).collect{ "--INPUT $it " }.join() } \
      --OUTPUT ${params.cohort}.vcf
	"""
}	

// Process SID recalibration
// Is suggested only if cohort sample size N > 30
process SID_VariantRecalibrator {

	cpus 1
	memory '12 GB'
	time '12h'
	
	tag "${params.cohort}"

    input:
	set file (vcf), file (vcfidx) from vcf_sid_ch
    file genome from ref
    file faidx from faidx_sid_ch
    file dict from dict_sid_ch

	output:
    set file("${params.cohort}.sid.recal"),file("${params.cohort}.sid.recal.idx"),file("${params.cohort}.sid.tranches") into sid_recal_ch

    script:
	"""
    gatk --java-options "-Xmx24g -Xms24g" \
      VariantRecalibrator \
      -R ${genome} \
      -V ${vcf} \
      --output ${params.cohort}.sid.recal \
      --tranches-file ${params.cohort}.sid.tranches \
      --trust-all-polymorphic \
      -an QD -an DP -an FS -an SOR -an ReadPosRankSum -an MQRankSum -an InbreedingCoeff \
      -mode INDEL \
      --max-gaussians 4 \
      -resource mills,known=false,training=true,truth=true,prior=12:${mills_resource_vcf} \
      -resource axiomPoly,known=false,training=true,truth=false,prior=10:${axiomPoly_resource_vcf} \
      -resource dbsnp,known=true,training=false,truth=false,prior=2:${dbsnp_resource_vcf}
	
	"""
}	

// Process SNV recalibration
process SNV_VariantRecalibrator {

	cpus 1
	memory '12 GB'
	time '12h'
	
	tag "${params.cohort}"

    input:
	set file (vcf), file (vcfidx) from vcf_snv_ch
    file genome from ref
    file faidx from faidx_snv_ch
    file dict from dict_snv_ch

	output:
    set file("${params.cohort}.snv.recal"),file("${params.cohort}.snv.recal.idx"),file("${params.cohort}.snv.tranches") into snv_recal_ch

    script:
	"""
    gatk --java-options "-Xmx90g -Xms90g" \
      VariantRecalibrator \
      -R ${genome} \
      -V ${vcf} \
      --output ${params.cohort}.snv.recal \
      --tranches-file ${params.cohort}.snv.tranches \
      --trust-all-polymorphic \
      -an QD -an MQ -an MQRankSum -an ReadPosRankSum -an FS -an SOR -an DP -an InbreedingCoeff \
      -mode SNP \
      --max-gaussians 6 \
      -resource hapmap,known=false,training=true,truth=true,prior=15:${hapmap_resource_vcf} \
      -resource omni,known=false,training=true,truth=true,prior=12:${omni_resource_vcf} \
      -resource 1000G,known=false,training=true,truth=false,prior=10:${one_thousand_genomes_resource_vcf} \
      -resource dbsnp,known=true,training=false,truth=false,prior=7:${dbsnp_resource_vcf}
	
	"""
}	

// Process Apply SNV and SID recalibrations
process ApplyRecalibration {

	cpus 1 
	memory '7 GB'
	time '12h'
	
	tag "${params.cohort}"

	publishDir params.output_dir, mode: 'copy'

    input:
	set file (input_vcf), file (input_vcf_idx) from vcf_recal_ch
	set file (indels_recalibration), file (indels_recalibration_idx), file (indels_tranches) from sid_recal_ch
	set file (snps_recalibration), file (snps_recalibration_idx), file (snps_tranches) from snv_recal_ch

	output:
    set file("${params.cohort}.recalibrated.vcf"),file("${params.cohort}.recalibrated.vcf.idx") into vcf_final_ch

    script:
	"""
    gatk --java-options "-Xmx5g -Xms5g" \
      ApplyVQSR \
      -O tmp.indel.recalibrated.vcf \
      -V ${input_vcf} \
      --recal-file ${indels_recalibration} \
      --tranches-file ${indels_tranches} \
      --truth-sensitivity-filter-level 99.0 \
      --exclude-filtered \
      --create-output-variant-index true \
      -mode INDEL

    gatk --java-options "-Xmx5g -Xms5g" \
      ApplyVQSR \
      -O ${params.cohort}.recalibrated.vcf \
      -V tmp.indel.recalibrated.vcf \
      --recal-file ${snps_recalibration} \
      --tranches-file ${snps_tranches} \
      --truth-sensitivity-filter-level 99.5 \
      --exclude-filtered \
      --create-output-variant-index true \
      -mode SNP
		
	"""
}	






