spades_modes = [['spades', ''], ['metaspades', '--meta']]
input_modes = ['paired-only', 'all']

Channel.fromFilePairs(params.reads)
    .multiMap{it ->
	qc: it
	trimming: it}
    .set{RAW_FASTQ}

process PreQC {
    tag {"preQC-${sample}"}
    publishDir params.outdir+"/0-preQC", mode: "copy", pattern: "*.html"

    input:
    tuple val(sample), file(fastqs) from RAW_FASTQ.qc

    output:
    file("*.html")
    file("*.zip") into PRE_QC_FOR_MULTIQC

    script:
    """
    fastqc -t ${task.cpus} *.fastq*
    """
}

process PreMultiQC {
    tag {"preMultiQC"}
    publishDir params.outdir+"/0-preQC", mode: "copy"

    input:
    file f from PRE_QC_FOR_MULTIQC.collect()

    output:
    file("multiqc*.html")

    script:
    """
    multiqc .
    """
}

process Trimming {
    // Quality filter and trimming
    tag { "trimmomatic-${sample}" }
    publishDir params.outdir+"/1-trimming", mode: "copy"

    input:
    tuple val(sample), file(fastqs) from RAW_FASTQ.trimming

    output:
    tuple val(sample), file("*_paired_R*.fastq.gz"), file("*_unpaired.fastq.gz") into TRIMMED_FASTQ

    script:
    """
    #!/usr/bin/env bash

    [ "${params.adapters}" = "null" ] && args="" || args="ILLUMINACLIP:${params.adapters}:2:30:10:2:keepBothReads"
    args=""

    java -jar ${HOME}/.local/src/Trimmomatic-0.39/trimmomatic-0.39.jar PE -threads ${task.cpus} \
        ${fastqs} \
        ${sample}_paired_R1.fastq.gz ${sample}_unpaired_R1.fastq.gz \
	${sample}_paired_R2.fastq.gz ${sample}_unpaired_R2.fastq.gz \
	\$args LEADING:3 MINLEN:100 

    cat *_unpaired_R*.fastq.gz > ${sample}_unpaired.fastq.gz
    """
}

TRIMMED_FASTQ.multiMap{it ->
    qc: it
    assembly: [it[1][0], it[1][1], it[2]]
    coverage: it[0..1]
}.set{FILTERED_FASTQ}

process PostQC {
    tag {"postQC_${sample}"}
    publishDir params.outdir+"/2-postQC", mode: "copy", pattern: "*.html"

    input:
    tuple val(sample), file(paired_fq), file(unpaired_fq) from FILTERED_FASTQ.qc

    output:
    file("*.html")
    file("*.zip") into POST_QC_FOR_MULTIQC

    script:
    """
    fastqc *fastq.gz
    """
}

process PostMultiQC {
    tag {"postMultiQC"}
    publishDir params.outdir+"/2-postQC", mode: "copy"

    input:
    file f from POST_QC_FOR_MULTIQC.collect()

    output:
    file("multiqc*.html")

    script:
    """
    multiqc .
    """
}

process MetaspadesAssembly {
    tag {"metaSPAdes"}
    publishDir params.outdir+"/3-assemblies", mode: "copy"

    input:
    each assembly_mode from spades_modes
    each input_mode from input_modes
    file f from FILTERED_FASTQ.assembly.collect()

    output:
    tuple(val("${assembly_mode[0]}_${input_mode}"), file("assembly_*.fasta")) into CONTIGS
    
    script:
    """
    cat *_paired_R1.fastq.gz > paired_R1.fastq.gz
    cat *_paired_R2.fastq.gz > paired_R2.fastq.gz
    cat *_unpaired.fastq.gz > unpaired.fastq.gz

    spades_path="${HOME}/.local/src/SPAdes-3.14.1-Linux/bin"
    
    [ "${input_mode}" = "paired-only" ] && input_mode="" || input_mode="-s unpaired.fastq.gz"
    \${spades_path}/spades.py ${assembly_mode[1]} -k 21,33,55,77 \
        -1 paired_R1.fastq.gz -2 paired_R2.fastq.gz \$input_mode \
        -t ${task.cpus} -m 80 -o spades_output

    mv spades_output/scaffolds.fasta "assembly_${assembly_mode[0]}_${input_mode}.fasta"
    """    
}

CONTIGS.multiMap{it ->
    cov: it
    coconet: it
    metabat2: it
}.set{ASSEMBLY}

process CoverageIndex {
    tag {"coverageIndex-${mode}"}

    input:
    tuple(val(mode), file(assembly)) from ASSEMBLY.cov

    output:
    tuple(val(mode), file('db*')) into BWA_DB

    script:
    """
    bwa index ${assembly} -p db
    """
}

process Coverage {
    tag {"coverage-${sample}-${mode}"}
    publishDir params.outdir+"/4-coverage", mode: "copy"

    input:
    tuple(val(sample), file(paired_trimmed_fq), val(mode), file(index)) from FILTERED_FASTQ.coverage.combine(BWA_DB)

    output:
    tuple(val(mode), file('coverage*.bam')) into COVERAGE 
    
    script:
    """
    bwa mem -a -M -t 50 db ${paired_trimmed_fq} \
        | samtools sort -@ ${task.cpus} -o coverage_${mode}_${sample}.bam
    """    
}

COVERAGE.groupTuple().multiMap{it ->
    coconet: it
    metabat2: it}.set{FOR_BINNING}

process CoCoNet {
    tag {"binning-coconet-${mode}"}
    publishDir params.outdir+"/4-binning", mode: "copy"
    errorStrategy 'ignore'

    input:
    tuple(val(mode), file(fasta), file(bams)) from ASSEMBLY.coconet.join(FOR_BINNING.coconet)

    output:
    file('coconet_bins*.csv') into COCONET_BINS

    script:
    """
    coconet --fasta ${fasta} --coverage ${bams} --output output
    mv output/bins_*.csv coconet_bins-${mode}.csv
    """
}

process Metabat2 {
    tag {"binning-metabat2-${mode}"}
    publishDir params.outdir+"/4-binning", mode: "copy"
    container "metabat/metabat"

    input:
    tuple(val(mode), file(fasta), file(bams)) from ASSEMBLY.metabat2.join(FOR_BINNING.metabat2)

    output:
    file('metabat2_bins*.csv') into METABAT2_BINS

    script:
    """
    runMetaBat.sh -l ${fasta} ${bams} --saveCls -o metabat_output
    # mv *metabat* metabat2_outputs
    """
}
