package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	qinternal "github.com/royalicing/qip/internal"
	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero"
)

type runPipelineStep struct {
	index          int
	source         string
	kind           string
	inputEncoding  string
	inputType      string
	outputEncoding string
	outputType     string
	inputCapBytes  uint64
	outputCapBytes uint64
	bufferBytes    uint64
	note           string
}

type runPipelinePlan struct {
	steps            []runPipelineStep
	totalBufferBytes uint64
	warnings         []string
}

type runPipelinePlanningOptions struct {
	capacitiesMustFit bool
}

type pipelineComponentKind uint8

const (
	pipelineComponentContent pipelineComponentKind = iota
	pipelineComponentTile
	pipelineComponentInteractive
)

type pipelineComponentDescription struct {
	source               string
	kind                 pipelineComponentKind
	content              pipelineContentDescription
	tileInputCap         uint64
	tileHaloPx           int
	interactiveWidth     int
	interactiveHeight    int
	interactiveOutputCap uint64
}

type pipelineContentDescription struct {
	inputCapBytes                uint64
	inputEncoding                dataEncoding
	hasOutput                    bool
	outputCapBytes               uint64
	outputEncoding               dataEncoding
	declaredInputContentType     string
	hasDeclaredInputContentType  bool
	declaredOutputContentType    string
	hasDeclaredOutputContentType bool
}

func describePipelineContent(contract runModuleContract) pipelineContentDescription {
	return pipelineContentDescription{
		inputCapBytes:                contract.inputCapBytes,
		inputEncoding:                contract.inputEncoding,
		hasOutput:                    contract.hasOutput,
		outputCapBytes:               contract.outputCapBytes,
		outputEncoding:               contract.outputEncoding,
		declaredInputContentType:     contract.declaredInputContentType,
		hasDeclaredInputContentType:  contract.hasDeclaredInputContentType,
		declaredOutputContentType:    contract.declaredOutputContentType,
		hasDeclaredOutputContentType: contract.hasDeclaredOutputContentType,
	}
}

func (description pipelineContentDescription) runContract() runModuleContract {
	return runModuleContract{
		inputCapBytes:                description.inputCapBytes,
		inputEncoding:                description.inputEncoding,
		hasOutput:                    description.hasOutput,
		outputCapBytes:               description.outputCapBytes,
		outputEncoding:               description.outputEncoding,
		declaredInputContentType:     description.declaredInputContentType,
		hasDeclaredInputContentType:  description.hasDeclaredInputContentType,
		declaredOutputContentType:    description.declaredOutputContentType,
		hasDeclaredOutputContentType: description.hasDeclaredOutputContentType,
	}
}

type preparedRunPipeline struct {
	pipeline *qinternal.Pipeline
	plan     runPipelinePlan
}

func dryRunCmd(args []string) {
	config, err := parseRunCommandArgs(args, "dry run")
	if err != nil {
		gameOver("%v", err)
	}
	if err := executeDryRun(context.Background(), config, os.Stdout); err != nil {
		gameOver("%v", err)
	}
}

func executeDryRun(baseCtx context.Context, config runCommandConfig, out io.Writer) error {
	execCtx, cancel := wasmruntime.WithExecutionTimeout(baseCtx, time.Duration(config.timeoutMS)*time.Millisecond)
	defer cancel()

	prepared, err := prepareRunPipelineFromInvocations(execCtx, config.componentInvocations, config.opts)
	if err != nil {
		return err
	}
	defer prepared.pipeline.Close(context.Background())
	writeDryRunReport(out, prepared.plan)
	return nil
}

func prepareRunPipelineFromInvocations(ctx context.Context, invocations []ComponentInvocation, opts options) (preparedRunPipeline, error) {
	pipeline, err := buildPipelineFromInvocations(ctx, invocations, opts)
	if err != nil {
		return preparedRunPipeline{}, err
	}
	descriptions, err := describeRunPipeline(ctx, pipeline)
	if err != nil {
		_ = pipeline.Close(context.Background())
		return preparedRunPipeline{}, err
	}
	plan, err := planRunPipelineWithOptions(descriptions, runPipelinePlanningOptions{
		capacitiesMustFit: opts.capacitiesMustFit,
	})
	if err != nil {
		_ = pipeline.Close(context.Background())
		return preparedRunPipeline{}, err
	}
	return preparedRunPipeline{pipeline: pipeline, plan: plan}, nil
}

func describeRunPipeline(ctx context.Context, pipeline *qinternal.Pipeline) ([]pipelineComponentDescription, error) {
	descriptions := make([]pipelineComponentDescription, 0, len(pipeline.Stages))
	stepIndex := 0
	for pipelineStageIndex, stage := range pipeline.Stages {
		switch typed := stage.(type) {
		case *qinternal.RunStage:
			driver, ok := typed.Driver.(*wasmRunDriver)
			if !ok {
				return nil, fmt.Errorf("stage %d: unsupported run driver", pipelineStageIndex+1)
			}
			if len(pipeline.Stages) == 1 {
				interactive, ok, err := inspectInteractivePipelineStep(ctx, driver, stepIndex+1)
				if err != nil {
					return nil, err
				}
				if ok {
					return []pipelineComponentDescription{interactive}, nil
				}
			}
			contract, err := inspectContentPipelineStep(ctx, driver, stepIndex+1)
			if err != nil {
				return nil, err
			}
			descriptions = append(descriptions, pipelineComponentDescription{
				source:  driver.modulePath,
				kind:    pipelineComponentContent,
				content: describePipelineContent(contract),
			})
			stepIndex++

		case *qinternal.TileGroupStage:
			for _, tileDriver := range typed.Drivers {
				driver, ok := tileDriver.(*wasmTileModuleDriver)
				if !ok {
					return nil, fmt.Errorf("step %d: unsupported tile driver", stepIndex+1)
				}
				descriptions = append(descriptions, pipelineComponentDescription{
					source:       driver.modulePath,
					kind:         pipelineComponentTile,
					tileInputCap: driver.inputCap,
					tileHaloPx:   driver.haloPx,
				})
				stepIndex++
			}

		default:
			return nil, fmt.Errorf("stage %d: unsupported pipeline stage %T", pipelineStageIndex+1, stage)
		}
	}
	return descriptions, nil
}

// planRunPipeline is deliberately pure: callers provide inspected component
// descriptions, and it returns the exact ordered plan used for validation,
// reporting, and execution preparation without loading or calling Wasm.
func planRunPipeline(descriptions []pipelineComponentDescription) (runPipelinePlan, error) {
	return planRunPipelineWithOptions(descriptions, runPipelinePlanningOptions{})
}

func planRunPipelineWithOptions(descriptions []pipelineComponentDescription, planningOptions runPipelinePlanningOptions) (runPipelinePlan, error) {
	var plan runPipelinePlan
	currentContentType := ""
	var currentEncoding dataEncoding
	hasCurrentEncoding := false
	previousContentOutputCap := uint64(0)
	previousWasContent := false
	previousOutputStep := 0
	previousOutputSource := ""

	for stepIndex, description := range descriptions {
		switch description.kind {
		case pipelineComponentContent:
			contract := description.content.runContract()
			if hasCurrentEncoding && !pipelineEncodingAccepted(currentEncoding, contract.inputEncoding) {
				return plan, fmt.Errorf(
					"step %d (%s): input encoding mismatch: expected %s, got %s",
					stepIndex+1,
					description.source,
					dryEncodingName(contract.inputEncoding),
					dryEncodingName(currentEncoding),
				)
			}
			capacityWarning := ""
			if previousWasContent && previousContentOutputCap > contract.inputCapBytes {
				if planningOptions.capacitiesMustFit {
					return plan, fmt.Errorf(
						"step %d (%s): capacities must fit: step %d (%s) output capacity is %s, but step %d (%s) input capacity is %s",
						stepIndex+1,
						description.source,
						previousOutputStep,
						previousOutputSource,
						formatBytesWithExact(previousContentOutputCap),
						stepIndex+1,
						description.source,
						formatBytesWithExact(contract.inputCapBytes),
					)
				}
				capacityWarning = fmt.Sprintf(
					"step %d (%s): previous output capacity %s exceeds this input capacity %s; qip run remains valid when the actual intermediate output fits",
					stepIndex+1,
					description.source,
					formatBytesWithExact(previousContentOutputCap),
					formatBytesWithExact(contract.inputCapBytes),
				)
				plan.warnings = append(plan.warnings, capacityWarning)
			}
			if stepIndex > 0 && contract.hasDeclaredInputContentType && currentContentType != contract.declaredInputContentType {
				previousType := fmt.Sprintf("%q", currentContentType)
				if currentContentType == "" {
					previousType = "no declared content type"
				}
				return plan, fmt.Errorf(
					"step %d (%s): content type mismatch: step %d (%s) output is %s, but step %d (%s) input is %q",
					stepIndex+1,
					description.source,
					previousOutputStep,
					previousOutputSource,
					previousType,
					stepIndex+1,
					description.source,
					contract.declaredInputContentType,
				)
			}

			effectiveInputType, outputType, err := resolveRunModuleContentType(
				contract,
				currentContentType,
				stepIndex == 0,
				ContentTypeCheckingStrong,
				description.source,
			)
			if err != nil {
				return plan, fmt.Errorf("step %d (%s): %w", stepIndex+1, description.source, err)
			}

			step := runPipelineStep{
				index:          stepIndex + 1,
				source:         description.source,
				kind:           "Content",
				inputEncoding:  dryEncodingName(contract.inputEncoding),
				inputType:      effectiveInputType,
				outputEncoding: "scalar result",
				outputType:     outputType,
				inputCapBytes:  contract.inputCapBytes,
				bufferBytes:    contract.inputCapBytes,
				note:           capacityWarning,
			}
			if contract.hasOutput {
				step.outputEncoding = dryEncodingName(contract.outputEncoding)
				step.outputCapBytes = contract.outputCapBytes
				step.bufferBytes += contract.outputCapBytes
			}
			plan.steps = append(plan.steps, step)
			plan.totalBufferBytes += step.bufferBytes
			currentContentType = outputType
			currentEncoding = contract.outputEncoding
			hasCurrentEncoding = contract.hasOutput
			previousContentOutputCap = contract.outputCapBytes
			previousWasContent = contract.hasOutput
			if contract.hasOutput {
				previousOutputStep = stepIndex + 1
				previousOutputSource = description.source
			}

		case pipelineComponentTile:
			if hasCurrentEncoding && currentEncoding != dataEncodingRaw {
				return plan, fmt.Errorf("step %d (%s): tile component requires raw image/bmp bytes, got %s", stepIndex+1, description.source, dryEncodingName(currentEncoding))
			}
			if currentContentType != "" && currentContentType != "image/bmp" {
				return plan, fmt.Errorf("step %d (%s): tile component requires image/bmp input, got %q", stepIndex+1, description.source, currentContentType)
			}
			tileSpan := tileSize + 2*description.tileHaloPx
			requiredBytes := uint64(tileSpan * tileSpan * 4 * 4)
			if description.tileInputCap < requiredBytes {
				return plan, fmt.Errorf(
					"step %d (%s): tile input capacity %d bytes is smaller than the %dx%d RGBA32Float tile buffer (%d bytes)",
					stepIndex+1, description.source, description.tileInputCap, tileSpan, tileSpan, requiredBytes,
				)
			}
			step := runPipelineStep{
				index:          stepIndex + 1,
				source:         description.source,
				kind:           "Tile",
				inputEncoding:  "RGBA32Float tile",
				inputType:      "image/bmp",
				outputEncoding: "RGBA32Float tile (in-place)",
				outputType:     "image/bmp",
				inputCapBytes:  description.tileInputCap,
				outputCapBytes: description.tileInputCap,
				bufferBytes:    description.tileInputCap,
				note:           fmt.Sprintf("%dx%d tile including %d px halo", tileSpan, tileSpan, description.tileHaloPx),
			}
			plan.steps = append(plan.steps, step)
			plan.totalBufferBytes += step.bufferBytes
			currentContentType = "image/bmp"
			currentEncoding = dataEncodingRaw
			hasCurrentEncoding = true
			previousContentOutputCap = 0
			previousWasContent = false
			previousOutputStep = stepIndex + 1
			previousOutputSource = description.source

		case pipelineComponentInteractive:
			if len(descriptions) != 1 {
				return plan, fmt.Errorf("step %d (%s): Interactive components can only be run alone", stepIndex+1, description.source)
			}
			step := runPipelineStep{
				index:          stepIndex + 1,
				source:         description.source,
				kind:           "Interactive",
				inputEncoding:  "interactive events",
				inputType:      "not applicable",
				outputEncoding: "RGBA8 sRGB",
				outputType:     "image/bmp",
				outputCapBytes: description.interactiveOutputCap,
				bufferBytes:    description.interactiveOutputCap,
				note:           fmt.Sprintf("%dx%d frame; qip run encodes the frame as BMP", description.interactiveWidth, description.interactiveHeight),
			}
			plan.steps = append(plan.steps, step)
			plan.totalBufferBytes += step.bufferBytes

		default:
			return plan, fmt.Errorf("step %d (%s): unsupported component kind %d", stepIndex+1, description.source, description.kind)
		}
	}
	return plan, nil
}

func inspectContentPipelineStep(ctx context.Context, driver *wasmRunDriver, stepIndex int) (runModuleContract, error) {
	name := fmt.Sprintf("plan-content-%d", stepIndex)
	mod, err := driver.runtime.InstantiateModule(ctx, driver.compiled, wazero.NewModuleConfig().WithName(name))
	if err != nil {
		return runModuleContract{}, fmt.Errorf("step %d (%s): Wasm module could not be instantiated", stepIndex, driver.modulePath)
	}
	defer mod.Close(ctx)
	if err := applyModuleUniforms(ctx, mod, driver.uniforms); err != nil {
		return runModuleContract{}, fmt.Errorf("step %d (%s): %w", stepIndex, driver.modulePath, err)
	}
	contract, err := inspectRunModuleContract(ctx, mod)
	if err != nil {
		return runModuleContract{}, fmt.Errorf("step %d (%s): %w", stepIndex, driver.modulePath, err)
	}
	return contract, nil
}

func inspectInteractivePipelineStep(ctx context.Context, driver *wasmRunDriver, stepIndex int) (pipelineComponentDescription, bool, error) {
	var description pipelineComponentDescription
	mod, err := driver.runtime.InstantiateModule(ctx, driver.compiled, wazero.NewModuleConfig().WithName("plan-interactive"))
	if err != nil {
		return description, false, fmt.Errorf("step %d (%s): Wasm module could not be instantiated", stepIndex, driver.modulePath)
	}
	defer mod.Close(ctx)

	requiredFunctions := []string{"key_event", "pointer_event", "tick", "render", "render_width_px", "render_height_px"}
	for _, name := range requiredFunctions {
		if mod.ExportedFunction(name) == nil {
			return description, false, nil
		}
	}
	if mod.Memory() == nil {
		return description, false, nil
	}
	if _, ok, err := getExportedValue(ctx, mod, "output_rgba8_srgb_bytes"); err != nil {
		return description, true, wasmruntime.HumanizeExecutionError(ctx, err)
	} else if !ok {
		return description, false, nil
	}
	if err := applyModuleUniforms(ctx, mod, driver.uniforms); err != nil {
		return description, true, fmt.Errorf("step %d (%s): %w", stepIndex, driver.modulePath, err)
	}

	widthValue, ok, err := getExportedValue(ctx, mod, "render_width_px")
	if err != nil {
		return description, true, wasmruntime.HumanizeExecutionError(ctx, err)
	}
	if !ok {
		return description, true, errors.New("interactive module missing render_width_px export")
	}
	heightValue, ok, err := getExportedValue(ctx, mod, "render_height_px")
	if err != nil {
		return description, true, wasmruntime.HumanizeExecutionError(ctx, err)
	}
	if !ok {
		return description, true, errors.New("interactive module missing render_height_px export")
	}
	outputValue, _, err := getExportedValue(ctx, mod, "output_rgba8_srgb_bytes")
	if err != nil {
		return description, true, wasmruntime.HumanizeExecutionError(ctx, err)
	}
	if !hasExportedValue(mod, "output_ptr") {
		return description, true, errors.New("interactive module missing output_ptr export")
	}

	width := int(int32(widthValue))
	height := int(int32(heightValue))
	if width <= 0 || height <= 0 {
		return description, true, fmt.Errorf("step %d (%s): interactive module reported invalid render size %dx%d", stepIndex, driver.modulePath, width, height)
	}
	expectedBytes := uint64(width) * uint64(height) * 4
	if outputValue != expectedBytes {
		return description, true, fmt.Errorf("step %d (%s): output_rgba8_srgb_bytes returned %d bytes, expected %d", stepIndex, driver.modulePath, outputValue, expectedBytes)
	}

	description = pipelineComponentDescription{
		source:               driver.modulePath,
		kind:                 pipelineComponentInteractive,
		interactiveWidth:     width,
		interactiveHeight:    height,
		interactiveOutputCap: outputValue,
	}
	return description, true, nil
}

func writeDryRunReport(out io.Writer, report runPipelinePlan) {
	fmt.Fprintf(out, "Pipeline compatible: %d step(s)\n", len(report.steps))
	for _, stage := range report.steps {
		fmt.Fprintf(out, "%d. %s — %s\n", stage.index, stage.source, stage.kind)
		fmt.Fprintf(out, "   Input:  encoding=%s, type=%s, capacity=%s\n", stage.inputEncoding, dryTypeName(stage.inputType), dryCapacityName(stage.inputCapBytes))
		fmt.Fprintf(out, "   Output: encoding=%s, type=%s, capacity=%s\n", stage.outputEncoding, dryTypeName(stage.outputType), dryCapacityName(stage.outputCapBytes))
		fmt.Fprintf(out, "   Buffers: %s\n", formatBytesWithExact(stage.bufferBytes))
		if stage.note != "" {
			fmt.Fprintf(out, "   Note: %s\n", stage.note)
		}
	}
	fmt.Fprintf(out, "Total declared buffer capacity: %s\n", formatBytesWithExact(report.totalBufferBytes))
	if len(report.warnings) > 0 {
		fmt.Fprintf(out, "Warnings: %d\n", len(report.warnings))
	}
}

func dryEncodingName(encoding dataEncoding) string {
	if encoding == dataEncodingUTF8 {
		return "UTF-8"
	}
	return "raw bytes"
}

func pipelineEncodingAccepted(actual, expected dataEncoding) bool {
	return actual == expected || (actual == dataEncodingUTF8 && expected == dataEncodingRaw)
}

func dryTypeName(contentType string) string {
	if strings.TrimSpace(contentType) == "" {
		return "unspecified"
	}
	return contentType
}

func dryCapacityName(bytes uint64) string {
	if bytes == 0 {
		return "none"
	}
	return formatBytesWithExact(bytes)
}

func formatBytesWithExact(bytes uint64) string {
	formatted := formatBytesIEC(bytes)
	if formatted == fmt.Sprintf("%d B", bytes) {
		return formatted
	}
	return fmt.Sprintf("%s (%d bytes)", formatted, bytes)
}
